{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Text.Decker.Filter.FragmentTemplate (expandFragmentTemplates) where

import Data.List qualified as List
import Data.Text qualified as Text
import Relude
import Text.Decker.Filter.Monad (Filter, meta, FilterState (templates))
import Text.Decker.Filter.Util (randomId)
import Text.Decker.Internal.Meta (lookupMetaOrElse )
import Text.Decker.Internal.Exception (DeckerException (..))
import Text.Pandoc hiding (lookupMeta, newStdGen, getTemplate)
import Text.Pandoc.Shared
import Text.Pandoc.Walk
import Text.Regex.TDFA.Text ()
import Text.Decker.Internal.URI (makeProjectPath)
import Text.DocTemplates (compileTemplateFile, toContext, Context)
import Data.Map.Strict qualified as Map
import Control.Exception (throw)
import Control.Concurrent.STM (modifyTVar)
import Data.Aeson (toJSON)
import System.FilePath ((<.>))
import Text.DocLayout
import Text.Decker.Internal.Common (supportDir)
import Development.Shake.FilePath ((</>))
import Control.Exception.Base (handle)

expandFragmentTemplates :: Pandoc -> Filter Pandoc
expandFragmentTemplates  document@(Pandoc meta blocks) =
  if lookupMetaOrElse False "experiments.fragment-templates" meta
    then Pandoc meta <$> (walkM expandBlockM blocks >>= walkM expandLinkM)
    else return document
  where
    -- Expands macro links in block contexts
    expandBlockM :: Block -> Filter Block
    expandBlockM (Para [link]) = do
      link <- expandLinkM link
      return (Para [link])
    expandBlockM (Plain [link]) = do
      link <- expandLinkM link
      return (Plain [link])
    expandBlockM block@(CodeBlock attr code) = expandCodeM block
    expandBlockM block = return block

    -- Expands macro links in inline contexts
    -- expandLinkM :: Inline -> Filter a
    expandLinkM link@(Link attr@(id, cls, kvs) inlines (url, title)) = do
      let rawKvs = map (\(k, v) -> (fromMaybe k $ Text.stripPrefix "data-" k, v)) kvs
      case parseInvocation inlines of
        Just (name, args) -> do
          let kvAttribs = List.filter ((/= "micro") . fst) rawKvs
          let targetArgs = [("url", url), ("title", title)]
          let posArgs = zip (map (("arg" <>) . show ) [1 .. (length args)]) args
          let allPosArgs = [("args", Text.unwords args)]
          let clsArgs = zip (map (("class" <>) . show ) [1 .. (length cls)]) cls
          let allClsArgs = [("classes", Text.unwords cls)]
          let allKvAttribs = [("attribs", unwords $ map (\(k, v) -> k <> "=\"" <> v <> "\"") kvAttribs)]
          rndId <- liftIO randomId
          let idArg = [("id", if Text.null id then rndId else id)]
          let arguments :: [(Text,Text)] = allPosArgs <> posArgs <> targetArgs <> idArg <> clsArgs <> allClsArgs <> kvAttribs <> allKvAttribs
          template <- getTemplate (toString name)
          let context :: Context Text = toContext $ toJSON $ Map.fromList arguments
          let text :: Text = render Nothing $ renderTemplate template context
          return $ RawInline "html" text
        Nothing ->
          return link
    expandLinkM link = return link

    expandCodeM block@(CodeBlock attr@(id, cls, kvs) code) = do
      let rawKvs = map (\(k, v) -> (fromMaybe k $ Text.stripPrefix "data-" k, v)) kvs
      let name = listToMaybe $ catMaybes [List.lookup "micro" rawKvs, Text.dropEnd 1 <$> find (Text.isSuffixOf "-") cls]
      case name of
        Just name -> do
          rndId <- ("id" <>) <$> liftIO randomId
          let kvAttribs = List.filter ((/= "micro") . fst) rawKvs
          let clsArgs = zip (map (("class" <>) . show ) [1 .. (length cls)]) cls
          let allClsArgs = [("classes", Text.unwords cls)]
          let allKvAttribs = [("attribs", unwords $ map (\(k, v) -> k <> "=\"" <> v <> "\"") kvAttribs)]
          let codeArg = [("code", Text.strip code)]
          let rndIdArg = [("rnd-id", rndId)]
          let idArg = [("id", if Text.null id then rndId else id)]
          let captionArg = [("caption", fromMaybe "" (List.lookup "caption" rawKvs))]
          let arguments :: [(Text,Text)] = codeArg <> clsArgs <> allClsArgs <> kvAttribs <> allKvAttribs <> rndIdArg <> idArg <> captionArg
          template <- getTemplate (toString name)
          let context :: Context Text = toContext $ toJSON $ Map.fromList arguments
          let text :: Text = render Nothing $ renderTemplate template context
          return $ RawBlock "html" text
        Nothing ->
          return block
    expandCodeM block = return block

    -- Parses a link text into a macro invocation, if possible. a macro name
    -- starts either with  a '§', or ends with a '-'
    parseInvocation inline =
      case second Text.words $ Text.splitAt 1 $ stringify inline of
        ("§", name : args) -> Just (name, args)
        _ -> case Text.words $ stringify inline of
          (name : args) | Text.isSuffixOf "-" name -> Just (Text.dropEnd 1 name, args)
          _ -> Nothing

getTemplate :: String -> Filter (Template Text)
getTemplate filename = do
  meta <- gets meta
  tvar <- gets templates
  templates <- liftIO $ readTVarIO tvar
  case Map.lookup filename templates of
    Nothing -> do
      template <- readTemplateFile (filename  <.> "html")
      atomically $ modifyTVar tvar (Map.insert filename template)
      return template
    Just template -> return template

readTemplateFile :: String -> Filter (Template Text)
readTemplateFile filename = do
  meta <- gets meta
  let base :: String = lookupMetaOrElse "." "decker.base-dir" meta
  let path1 = makeProjectPath base filename
  let path2 = supportDir </> "templates" </> filename

  -- compileTemplateFile throws exceptions if the file data can not be read, and
  -- returns (Left (Template a)) if the template cannot be compiled. this code
  -- tries two template locations in order and tries the second one only if the
  -- first one cannot be found. if the template cannot be found ist throws on
  -- either.
  template <- liftIO $
    handle (\(SomeException _) ->
      handle (\(SomeException err)->
                throw (ResourceException $ "Cannot find template file: " <> filename <> ": " <> show err))
             $ compileTemplateFile path2) $ compileTemplateFile path1
  case template of
    Right template -> return template
    Left err -> do
      return $ throw (ResourceException $ "Cannot parse template file: " <> filename <> ": " <> show err)