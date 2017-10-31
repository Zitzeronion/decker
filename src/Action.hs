{-- Author: Henrik Tramberend <henrik@tramberend.de> --}
module Action
  ( spawn
  , wantRepeat
  , dropSuffix
  , runHttpServer
  , replaceSuffix
  , replaceSuffixWith
  , globA
  , reloadBrowsers
  , calcTargets
  , calcSource
  , readMetaDataForDir
  , DeckerException(..)
  ) where

import Common
import Context
import Control.Exception
import Control.Monad
import Data.IORef
import Data.List as List
import Data.List.Extra as List
import Data.Maybe
import qualified Data.Yaml as Y
import Development.Shake
import Development.Shake.FilePath as SFP
import Project
import Server
import System.FilePath.Glob
import System.Process
import Meta

-- | Globs for files under the project dir in the Action monad. Returns absolute
-- pathes.
globA :: FilePattern -> Action [FilePath]
globA pat = do
  dirs <- getProjectDirs
  liftIO $
    filter (not . isPrefixOf (public dirs)) <$>
    globDir1 (compile pat) (project dirs)

-- Utility functions for shake based apps
spawn :: String -> Action ProcessHandle
spawn = liftIO . spawnCommand

-- Runs the built-in server on the given directory, if it is not already
-- running. If open is True a browser window is opended.
runHttpServer :: ProjectDirs -> Bool -> Action ()
runHttpServer dirs open = do
  server <- getServerHandle
  case server of
    Just _ -> return ()
    Nothing -> do
      let port = 8888
      server <- liftIO $ startHttpServer dirs port
      setServerHandle $ Just server
      when open $ cmd ("open http://localhost:" ++ show port :: String) :: Action ()

reloadBrowsers :: Action ()
reloadBrowsers = do
  server <- getServerHandle
  case server of
    Just handle -> liftIO $ reloadClients handle
    Nothing -> return ()

wantRepeat :: IORef Bool -> Action ()
wantRepeat justOnce = liftIO $ writeIORef justOnce False

-- | Calculates the target pathes from a list of source files.
calcTargets :: String -> String -> [FilePath] -> Action [FilePath]
calcTargets srcSuffix targetSuffix sources = do
  dirs <- getProjectDirs
  return $
    map
      (replaceSuffix srcSuffix targetSuffix .
       combine (public dirs) . makeRelative (project dirs))
      sources

-- | Calculate the source file from the target path. Calls need.
calcSource :: String -> String -> FilePath -> Action FilePath
calcSource targetSuffix srcSuffix target = do
  dirs <- getProjectDirs
  let src =
        (replaceSuffix targetSuffix srcSuffix .
         combine (project dirs) . makeRelative (public dirs))
          target
  need [src]
  return src
  -- | Removes the last suffix from a filename

dropSuffix s t = fromMaybe t (stripSuffix s t)

replaceSuffix srcSuffix targetSuffix filename =
  dropSuffix srcSuffix filename ++ targetSuffix

-- | Monadic version of suffix replacement for easy binding.
replaceSuffixWith :: String -> String -> [FilePath] -> Action [FilePath]
replaceSuffixWith suffix with pathes =
  return [dropSuffix suffix d ++ with | d <- pathes]

readMetaDataForDir :: FilePath -> Action Y.Value
readMetaDataForDir dir = walkUpTo dir
  where
    walkUpTo dir = do
      dirs <- getProjectDirs
      if equalFilePath (project dirs) dir
        then collectMeta dir
        else do
          fromAbove <- walkUpTo (takeDirectory dir)
          fromHere <- collectMeta dir
          return $ joinMeta fromHere fromAbove
    --
    collectMeta dir = do
      files <- liftIO $ globDir1 (compile "*-meta.yaml") dir
      need files
      meta <- mapM decodeYaml files
      return $ foldl joinMeta (Y.object []) meta
    --
    decodeYaml yamlFile = do
      result <- liftIO $ Y.decodeFileEither yamlFile
      case result of
        Right object@(Y.Object _) -> return object
        Right _ ->
          throw $
          YamlException $ "Top-level meta value must be an object: " ++ dir
        Left exception -> throw exception
