-- | A command handler
module Calamity.Commands.Handler
    ( CommandHandler(..)
    , addCommands
    , buildCommands
    , buildContext ) where

import           Calamity.Cache.Eff
import           Calamity.Client.Client
import           Calamity.Client.Types
import           Calamity.Commands.Command
import           Calamity.Commands.CommandUtils
import           Calamity.Commands.Context
import           Calamity.Commands.Dsl
import           Calamity.Commands.Error
import           Calamity.Commands.Group
import           Calamity.Commands.LocalWriter
import           Calamity.Commands.ParsePrefix
import           Calamity.Internal.Utils
import           Calamity.Types.Model.Channel
import           Calamity.Types.Model.User
import           Calamity.Types.Snowflake

import           Control.Lens                   hiding ( Context )
import           Control.Monad

import           Data.Char                      ( isSpace )
import qualified Data.HashMap.Lazy              as LH
import qualified Data.Text                      as S
import qualified Data.Text.Lazy                 as L

import           GHC.Generics

import qualified Polysemy                       as P
import qualified Polysemy.Error                 as P
import qualified Polysemy.Fail                  as P
import qualified Polysemy.Fixpoint              as P
import qualified Polysemy.Reader                as P

data CommandHandler = CommandHandler
  { groups   :: LH.HashMap S.Text Group
    -- ^ Top level groups
  , commands :: LH.HashMap S.Text Command
    -- ^ Top level commands
  }
  deriving ( Generic )

mapLeft :: (e -> e') -> Either e a -> Either e' a
mapLeft f (Left x)  = Left $ f x
mapLeft _ (Right x) = Right x

addCommands :: (BotC r, P.Member ParsePrefix r)
            => P.Sem (DSLState r) a
            -> P.Sem r (P.Sem r (), CommandHandler, a)
addCommands m = do
  (handler, res) <- buildCommands m
  remove <- react @'MessageCreateEvt $ \msg -> do
    err <- P.runError . P.runFail $ do
        Just (prefix, rest) <- parsePrefix msg
        (command, unparsedParams) <- P.fromEither $ mapLeft NotFound $ findCommand handler rest
        Just ctx <- buildContext msg prefix command unparsedParams
        P.fromEither =<< invokeCommand ctx (ctx ^. #command)
        pure ctx
    case err of
      Left e -> fire $ customEvt @"command-error" e
      Right (Right ctx) -> fire $ customEvt @"command-run" ctx
      Right _ -> pure () -- command wasn't parsed
  pure (remove, handler, res)

buildCommands :: P.Member (P.Final IO) r
              => P.Sem (DSLState r) a
              -> P.Sem r (CommandHandler, a)
buildCommands =
  ((\(groups, (cmds, a)) -> (CommandHandler groups cmds, a)) <$>) .
  P.fixpointToFinal .
  P.runReader [] .
  P.runReader (const "This command or group has no help.") .
  P.runReader Nothing .
  runLocalWriter @(LH.HashMap S.Text Group) .
  runLocalWriter @(LH.HashMap S.Text Command)

buildContext :: BotC r => Message -> L.Text -> Command -> L.Text -> P.Sem r (Maybe Context)
buildContext msg prefix command unparsed = (rightToMaybe <$>) . P.runFail $ do
  guild <- join <$> getGuild `traverse` (msg ^. #guildID)
  let member = guild ^? _Just . #members . ix (coerceSnowflake $ getID @User msg)
  let gchan = guild ^? _Just . #channels . ix (coerceSnowflake $ getID @Channel msg)
  Just channel <- case gchan of
    Just chan -> pure . pure $ GuildChannel' chan
    _         -> DMChannel' <<$>> getDM (coerceSnowflake $ getID @Channel msg)
  Just user <- getUser $ getID msg

  pure $ Context msg guild member channel user command prefix unparsed

nextWord :: L.Text -> (L.Text, L.Text)
nextWord = L.break isSpace . L.stripStart

firstEither :: Either e a -> Either e a -> Either e a
firstEither (Right l) _ = Right l
firstEither l (Left _)  = l
firstEither _ r         = r

findCommand :: CommandHandler -> L.Text -> Either [L.Text] (Command, L.Text)
findCommand handler msg = goH $ nextWord msg
  where
    goH :: (L.Text, L.Text) -> Either [L.Text] (Command, L.Text)
    goH ("", _) = Left []
    goH (x, xs) = attachSoFar x
      (((, xs) <$> attachInitial (LH.lookup (L.toStrict x) (handler ^. #commands)))
       `firstEither` (attachInitial (LH.lookup (L.toStrict x) (handler ^. #groups)) >>= goG (nextWord xs)))

    goG :: (L.Text, L.Text) -> Group -> Either [L.Text] (Command, L.Text)
    goG ("", _) _ = Left []
    goG (x, xs) g = attachSoFar x
      (((, xs) <$> attachInitial (LH.lookup (L.toStrict x) (g ^. #commands)))
       `firstEither` (attachInitial (LH.lookup (L.toStrict x) (g ^. #children)) >>= goG (nextWord xs)))

    attachInitial :: Maybe a -> Either [L.Text] a
    attachInitial (Just a) = Right a
    attachInitial Nothing = Left []

    attachSoFar :: L.Text -> Either [L.Text] a -> Either [L.Text] a
    attachSoFar cmd (Left xs) = Left (cmd:xs)
    attachSoFar _ r = r