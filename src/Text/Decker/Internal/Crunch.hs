{-# LANGUAGE NoImplicitPrelude #-}

module Text.Decker.Internal.Crunch where

import Control.Lens ((^.), (^?))
import Control.Monad
import Data.Aeson
import Data.Aeson.Lens
import qualified Data.List as List
import qualified Data.Map.Strict as Map
import Development.Shake
import Development.Shake.FilePath
import Relude
import System.Exit
import System.Process
import Text.Decker.Internal.Caches
import Text.Decker.Internal.Common
import Text.Decker.Internal.Helper
import Text.Decker.Project.Project
import Text.Decker.Server.Video

-- | Rules for transcoding videos. Mp4 videos are recreated with higher
-- compression parameters if any of the recording fragments changed. Also, if
-- they have not yet been transcoded.
crunchRules :: Rules ()
crunchRules = do
  (getGlobalMeta, getDeps, getTemplate) <- prepCaches
  want ["mp4s"]
  phony "mp4s" $ do
    targets <- getDeps
    -- Need MP4 videos for each deck that has at least one WEBM fragment recorded.
    forM_ (Map.keys $ targets ^. decks) $ \deck -> do
      let source = makeRelative publicDir deck
      let pattern = dropSuffix "-deck.html" source <> "*.webm"
      webms <- getDirectoryFiles "" [pattern]
      unless (null webms) $ do
        need [replaceSuffix "-deck.html" "-recording.mp4" deck]
  alternatives $ do
    -- copy the crunched MP4 to public
    publicDir <//> "*-recording.mp4" %> \out -> do
      let src = makeRelative publicDir out
      need [src]
      putNormal $ "# copy recording (for " <> out <> ")"
      copyFileChanged src out
    -- crunch the WEBMs in the list if the list changed
    "**/*-recording.mp4" %> \out -> do
      -- this pattern includes single WEBMs as well as collections of numbered fragments
      let pattern = dropSuffix ".mp4" out <> "*.webm"
      webms <- getDirectoryFiles "" [pattern]
      putNormal $ "# collect WEBMs (for " <> intercalate ", " webms <> ")"
      -- only write the list if it would change and track the change
      let list = out <.> "list"
      writeFileChanged list (List.unlines $ map (\f -> "file '" <> takeFileName f <> "'") $ sort webms)
      putNormal $ "# ffmpeg (for " <> out <> ")"
      need webms
      liftIO $ do
        concatVideoMp4' slow list out
        removeFileIfExists list

-- | Reads the 'comment' meta data field from the video container. Return True
-- if the value is 'decker-crunched', False otherwise.
wasCrunched :: FilePath -> IO Bool
wasCrunched mp4 = do
  (code, stdout, stderr) <- readProcessWithExitCode "ffprobe" (["-print_format", "json", "-show_format"] <> [mp4]) ""
  case code of
    ExitFailure _ -> return False
    ExitSuccess -> do
      let json :: Maybe Value = decode $ encodeUtf8 stdout
      case json of
        Nothing -> return False
        Just json -> do
          let comment = json ^? (key "format" . key "tags" . key "comment" . _String)
          return (comment == Just "decker-crunched")
