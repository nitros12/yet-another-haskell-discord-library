-- | Something that can parse user input
module CalamityCommands.Parser (
  ParameterParser (..),
  Named,
  KleeneStarConcat,
  KleenePlusConcat,

  -- * Parameter parsing utilities
  ParserEffs,
  runCommandParser,
  ParserState (..),
  parseMP,
  SpannedError (..),
) where

import CalamityCommands.ParameterInfo

import Control.Lens hiding (Context)
import Control.Monad

import Data.Char (isSpace)
import Data.Generics.Labels ()
import Data.Kind
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (fromMaybe)
import Data.Semigroup
import qualified Data.Text as S
import qualified Data.Text.Lazy as L
import Data.Typeable

import GHC.Generics (Generic)
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)

import qualified Polysemy as P
import qualified Polysemy.Error as P
import qualified Polysemy.Reader as P
import qualified Polysemy.State as P

import Numeric.Natural (Natural)
import Text.Megaparsec hiding (parse)
import Text.Megaparsec.Char
import Text.Megaparsec.Char.Lexer (decimal, float, signed)

data SpannedError = SpannedError L.Text !Int !Int
  deriving (Show, Eq, Ord)

{- | The current state of the parser, used so that the entire remaining input is
 available.

 This is used instead of just concatenating parsers to allow for more
 flexibility, for example, this could be used to construct flag-style parsers
 that parse a parameter from anywhere in the input message.
-}
data ParserState = ParserState
  { -- | The current offset, or where the next parser should start parsing at
    off :: Int
  , -- | The input message ot parse
    msg :: L.Text
  }
  deriving (Show, Generic)

-- |
type ParserEffs c r =
  ( P.State ParserState
      ': P.Error (S.Text, L.Text) -- (failing parser name, error reason)
        ': P.Reader c -- the current parser state
          ': r -- context
  )

-- | Run a command parser, @ctx@ is the context, @t@ is the text input
runCommandParser :: c -> L.Text -> P.Sem (ParserEffs c r) a -> P.Sem r (Either (S.Text, L.Text) a)
runCommandParser ctx t = P.runReader ctx . P.runError . P.evalState (ParserState 0 t)

{- | A typeclass for things that can be parsed as parameters to commands.

 Any type that is an instance of ParamerParser can be used in the type level
 parameter @ps@ of 'CalamityCommands.Dsl.command',
 'CalamityCommands.CommandUtils.buildCommand', etc.
-}
class Typeable a => ParameterParser (a :: Type) c r where
  type ParserResult a

  type ParserResult a = a

  parameterInfo :: ParameterInfo
  default parameterInfo :: ParameterInfo
  parameterInfo = ParameterInfo Nothing (typeRep $ Proxy @a) (parameterDescription @a @c @r)

  parameterDescription :: S.Text

  parse :: P.Sem (ParserEffs c r) (ParserResult a)

{- | A named parameter, used to attach the name @s@ to a type in the command's
 help output
-}
data Named (s :: Symbol) (a :: Type)

instance (KnownSymbol s, ParameterParser a c r) => ParameterParser (Named s a) c r where
  type ParserResult (Named s a) = ParserResult a

  parameterInfo =
    let ParameterInfo _ type_ typeDescription = parameterInfo @a @c @r
     in ParameterInfo (Just . S.pack . symbolVal $ Proxy @s) type_ typeDescription

  parameterDescription = parameterDescription @a @c @r

  parse = mapE (_1 .~ parserName @(Named s a) @c @r) $ parse @a @c @r

parserName :: forall a c r. ParameterParser a c r => S.Text
parserName =
  let ParameterInfo (fromMaybe "" -> name) type_ _ = parameterInfo @a @c @r
   in name <> ":" <> S.pack (show type_)

mapE :: P.Member (P.Error e) r => (e -> e) -> P.Sem r a -> P.Sem r a
mapE f m = P.catch m (P.throw . f)

{- | Parse a paremeter using a MegaParsec parser.

 On failure this constructs a nice-looking megaparsec error for the failed parameter.
-}
parseMP ::
  -- | The name of the parser
  S.Text ->
  -- | The megaparsec parser
  ParsecT SpannedError L.Text (P.Sem (P.Reader c ': r)) a ->
  P.Sem (ParserEffs c r) a
parseMP n m = do
  s <- P.get
  res <- P.raise . P.raise $ runParserT (skipN (s ^. #off) *> trackOffsets (space *> m)) "" (s ^. #msg)
  case res of
    Right (a, offset) -> do
      P.modify (#off +~ offset)
      pure a
    Left s -> P.throw (n, L.pack $ errorBundlePretty s)

instance ParameterParser L.Text c r where
  parse = parseMP (parserName @L.Text) item
  parameterDescription = "word or quoted string"

instance ParameterParser S.Text c r where
  parse = parseMP (parserName @S.Text) (L.toStrict <$> item)
  parameterDescription = "word or quoted string"

instance ParameterParser Integer c r where
  parse = parseMP (parserName @Integer) (signed mempty decimal)
  parameterDescription = "number"

instance ParameterParser Natural c r where
  parse = parseMP (parserName @Natural) decimal
  parameterDescription = "number"

instance ParameterParser Int c r where
  parse = parseMP (parserName @Int) (signed mempty decimal)
  parameterDescription = "number"

instance ParameterParser Word c r where
  parse = parseMP (parserName @Word) decimal
  parameterDescription = "number"

instance ParameterParser Float c r where
  parse = parseMP (parserName @Float) (signed mempty (try float <|> decimal))
  parameterDescription = "number"

instance ParameterParser a c r => ParameterParser (Maybe a) c r where
  type ParserResult (Maybe a) = Maybe (ParserResult a)

  parse = P.catch (Just <$> parse @a) (const $ pure Nothing)
  parameterDescription = "optional " <> parameterDescription @a @c @r

instance (ParameterParser a c r, ParameterParser b c r) => ParameterParser (Either a b) c r where
  type ParserResult (Either a b) = Either (ParserResult a) (ParserResult b)

  parse = do
    l <- parse @(Maybe a) @c @r
    case l of
      Just l' -> pure (Left l')
      Nothing ->
        Right <$> parse @b @c @r
  parameterDescription = "either '" <> parameterDescription @a @c @r <> "' or '" <> parameterDescription @b @c @r <> "'"

instance ParameterParser a c r => ParameterParser [a] c r where
  type ParserResult [a] = [ParserResult a]

  parse = go []
   where
    go :: [ParserResult a] -> P.Sem (ParserEffs c r) [ParserResult a]
    go l =
      P.catch (Just <$> parse @a) (const $ pure Nothing) >>= \case
        Just a -> go $ l <> [a]
        Nothing -> pure l

  parameterDescription = "zero or more '" <> parameterDescription @a @c @r <> "'"

instance (ParameterParser a c r, Typeable a) => ParameterParser (NonEmpty a) c r where
  type ParserResult (NonEmpty a) = NonEmpty (ParserResult a)

  parse = do
    a <- parse @a
    as <- parse @[a]
    pure $ a :| as

  parameterDescription = "one or more '" <> parameterDescription @a @c @r <> "'"

{- | A parser that consumes zero or more of @a@ then concatenates them together.

 @'KleeneStarConcat' 'L.Text'@ therefore consumes all remaining input.
-}
data KleeneStarConcat (a :: Type)

instance (Monoid (ParserResult a), ParameterParser a c r) => ParameterParser (KleeneStarConcat a) c r where
  type ParserResult (KleeneStarConcat a) = ParserResult a

  parse = mconcat <$> parse @[a]
  parameterDescription = "zero or more '" <> parameterDescription @a @c @r <> "'"

instance {-# OVERLAPS #-} ParameterParser (KleeneStarConcat L.Text) c r where
  type ParserResult (KleeneStarConcat L.Text) = ParserResult L.Text

  -- consume rest on text just takes everything remaining
  parse = parseMP (parserName @(KleeneStarConcat L.Text)) manySingle
  parameterDescription = "the remaining input"

instance {-# OVERLAPS #-} ParameterParser (KleeneStarConcat S.Text) c r where
  type ParserResult (KleeneStarConcat S.Text) = ParserResult S.Text

  -- consume rest on text just takes everything remaining
  parse = parseMP (parserName @(KleeneStarConcat S.Text)) (L.toStrict <$> manySingle)
  parameterDescription = "the remaining input"

{- | A parser that consumes one or more of @a@ then concatenates them together.

 @'KleenePlusConcat' 'L.Text'@ therefore consumes all remaining input.
-}
data KleenePlusConcat (a :: Type)

instance (Semigroup (ParserResult a), ParameterParser a c r) => ParameterParser (KleenePlusConcat a) c r where
  type ParserResult (KleenePlusConcat a) = ParserResult a

  parse = sconcat <$> parse @(NonEmpty a)
  parameterDescription = "one or more '" <> parameterDescription @a @c @r <> "'"

instance {-# OVERLAPS #-} ParameterParser (KleenePlusConcat L.Text) c r where
  type ParserResult (KleenePlusConcat L.Text) = ParserResult L.Text

  -- consume rest on text just takes everything remaining
  parse = parseMP (parserName @(KleenePlusConcat L.Text)) someSingle
  parameterDescription = "the remaining input"

instance {-# OVERLAPS #-} ParameterParser (KleenePlusConcat S.Text) c r where
  type ParserResult (KleenePlusConcat S.Text) = ParserResult S.Text

  -- consume rest on text just takes everything remaining
  parse = parseMP (parserName @(KleenePlusConcat S.Text)) (L.toStrict <$> someSingle)
  parameterDescription = "the remaining input"

instance (ParameterParser a c r, ParameterParser b c r) => ParameterParser (a, b) c r where
  type ParserResult (a, b) = (ParserResult a, ParserResult b)

  parse = do
    a <- parse @a
    b <- parse @b
    pure (a, b)
  parameterDescription = "'" <> parameterDescription @a @c @r <> "' then '" <> parameterDescription @b @c @r <> "'"

instance ParameterParser () c r where
  parse = parseMP (parserName @()) space
  parameterDescription = "whitespace"

instance ShowErrorComponent SpannedError where
  showErrorComponent (SpannedError t _ _) = L.unpack t
  errorComponentLen (SpannedError _ s e) = max 1 $ e - s

skipN :: (Stream s, Ord e) => Int -> ParsecT e s m ()
skipN n = void $ takeP Nothing n

trackOffsets :: MonadParsec e s m => m a -> m (a, Int)
trackOffsets m = do
  offs <- getOffset
  a <- m
  offe <- getOffset
  pure (a, offe - offs)

item :: MonadParsec e L.Text m => m L.Text
item = try quotedString <|> someNonWS

manySingle :: MonadParsec e s m => m (Tokens s)
manySingle = takeWhileP (Just "Any character") (const True)

someSingle :: MonadParsec e s m => m (Tokens s)
someSingle = takeWhile1P (Just "any character") (const True)

quotedString :: MonadParsec e L.Text m => m L.Text
quotedString =
  try (between (chunk "'") (chunk "'") (takeWhileP (Just "any character") (/= '\'')))
    <|> between (chunk "\"") (chunk "\"") (takeWhileP (Just "any character") (/= '"'))

someNonWS :: (Token s ~ Char, MonadParsec e s m) => m (Tokens s)
someNonWS = takeWhile1P (Just "any non-whitespace") (not . isSpace)
