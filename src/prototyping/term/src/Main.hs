module Main where

import           System.Environment               (getArgs, getProgName)
import           Control.Monad.Trans.Class        (lift)
import           Control.Monad.Trans.Either       (EitherT(EitherT), runEitherT, hoistEither)

import           Syntax.Raw                       (parseProgram)
import           Syntax.Internal                  (checkScope)
import           Check                            (checkProgram)
import           Term
import           Monad

checkFile :: FilePath -> IO (Either String (TCState LazySimpleScope))
checkFile file = (runEitherT :: EitherT String IO (TCState LazySimpleScope) -> IO (Either String (TCState LazySimpleScope))) $ do
    s   <- lift $ readFile file
    raw <- hoistEither $ showError "Parse" $ parseProgram s
    int <- hoistEither $ showError "Scope" $ checkScope raw
    EitherT $ fmap (showError "Type") $ checkProgram int
  where
    showError :: Show a => String -> Either a b -> Either String b
    showError errType = either (\err -> Left $ errType ++ " error: " ++ show err) Right

main :: IO ()
main = do
    args <- getArgs
    prog <- getProgName
    case args of
        [file] -> do
          errOrTs <- checkFile file
          case errOrTs of
            Left err -> putStrLn err
            _        -> return ()
        _      -> putStrLn $ "Usage: " ++ prog ++ " FILE"

