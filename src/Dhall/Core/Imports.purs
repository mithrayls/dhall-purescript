module Dhall.Core.Imports where

import Prelude

import Control.Alt ((<|>))
import Data.Array as Array
import Data.Foldable (class Foldable, foldMap, intercalate)
import Data.List (List(..), (:))
import Data.List as List
import Data.Maybe (Maybe(..), fromMaybe, isNothing)
import Data.String as String
import Data.Tuple (Tuple(..))
import Data.Unfoldable (class Unfoldable)

-- Most of this is just copied from dhall-haskell without further thought so far

-- | Internal representation of a directory that stores the path components in
-- | reverse order
-- | In other words, the directory `/foo/bar/baz` is encoded as
-- | `Directory { components = [ "baz", "bar", "foo" ] }`
newtype Directory = Directory (List String)
derive instance eqDirectory :: Eq Directory
derive instance ordDirectory :: Ord Directory

instance semigroupDirectory :: Semigroup Directory where
  append (Directory components₀) (Directory components₁) =
    Directory (components₁ <> components₀)
instance monoidDirectory :: Monoid Directory where
  mempty = Directory mempty

mkDirectory :: forall f. Foldable f => f String -> Directory
mkDirectory d = Directory $ List.reverse $ List.fromFoldable d

unDirectory :: forall f. Unfoldable f => Directory -> f String
unDirectory (Directory d) = d # List.reverse # List.toUnfoldable

parseDirectory :: String -> Directory
parseDirectory = mkDirectory <<< String.split (String.Pattern "/")

prettyDirectory :: Directory -> String
prettyDirectory (Directory components) = foldMap ("/" <> _) (List.reverse components)

canonicalizeDirectory :: Directory -> Directory
canonicalizeDirectory (Directory l0) = Directory (rec l0) where
  rec Nil = Nil
  rec ("." : l) = l
  rec (".." : l) = case rec l of
    Nil -> ".." : Nil
    ".." : l' -> ".." : ".." : l'
    _ : l' -> l'
  rec (d : l) = d : rec l

-- | A `File` is a `directory` followed by one additional path component
-- | representing the `file` name
newtype File = File { directory :: Directory, file :: String }
derive instance eqFile :: Eq File
derive instance ordFile :: Ord File
instance semigroupFile :: Semigroup File where
  append (File f1) (File f2) = File
    { directory: f1.directory <> f2.directory
    , file: f2.file
    }

mkFile :: Array String -> File
mkFile components = case Array.unsnoc components of
  Just { init: dir, last: file } -> File
    { directory: mkDirectory dir, file }
  Nothing -> File { directory: mempty, file: mempty }

parseFile :: String -> File
parseFile = mkFile <<< String.split (String.Pattern "/")

prettyFile :: File -> String
prettyFile (File { directory, file }) = prettyDirectory directory <> "/" <> file

canonicalizeFile :: File -> File
canonicalizeFile (File r) = File r { directory = canonicalizeDirectory r.directory }

data FilePrefix
  = Absolute -- Absolute path
  | Here -- Path relative to `.`
  | Parent -- Path relative to `..`
  | Home -- Path relative to `~`

derive instance eqFilePrefix :: Eq FilePrefix
derive instance ordFilePrefix :: Ord FilePrefix

prettyFilePrefix :: FilePrefix -> String
prettyFilePrefix Absolute = ""
prettyFilePrefix Here = "."
prettyFilePrefix Parent = ".."
prettyFilePrefix Home = "~"

parseFilePrefix :: String -> Maybe FilePrefix
parseFilePrefix "" = Just Absolute
parseFilePrefix ".." = Just Parent
parseFilePrefix "~" = Just Home
parseFilePrefix "." = Just Here
parseFilePrefix _ = Nothing

data Scheme = HTTP | HTTPS
derive instance eqScheme :: Eq Scheme
derive instance ordScheme :: Ord Scheme
instance showScheme :: Show Scheme where
  show HTTP = "http"
  show HTTPS = "https"

parseScheme :: String -> Maybe Scheme
parseScheme "http" = Just HTTP
parseScheme "https" = Just HTTPS
parseScheme _ = Nothing

newtype URL = URL
    { scheme    :: Scheme
    , authority :: String
    , path      :: File
    , query     :: Maybe String
    , headers   :: Maybe Headers
    }
derive instance eqURL :: Eq URL
derive instance ordURL :: Ord URL

parseURL :: String -> Maybe URL
parseURL url =
  let
    parseOne ty =
      Tuple ty <$> String.stripPrefix (String.Pattern (show ty <> "://")) url
  in do
    Tuple scheme restScheme <- parseOne HTTP <|> parseOne HTTPS
    Tuple query restQuery <- case String.split (String.Pattern "?") restScheme of
      [noQuery] -> pure $ Tuple Nothing noQuery
      [restQuery, query] -> pure $ Tuple (Just query) restQuery
      _ -> Nothing
    Tuple authority path <- case Array.uncons (String.split (String.Pattern "/") restQuery) of
      Just { head: authority, tail: path } -> pure $ Tuple authority (mkFile path)
      Nothing -> Nothing
    pure $ URL { scheme, authority, path, query, headers: Nothing }

prettyURL :: URL -> String
prettyURL (URL url) =
        show url.scheme
    <>  "://"
    <>  url.authority
    <>  prettyFile url.path
    <>  queryDoc
  where
    queryDoc = case url.query of
        Nothing -> ""
        Just q  -> "?" <> q

-- | The type of import (i.e. local vs. remote vs. environment)
data ImportType
  -- Local path
  = Local FilePrefix File
  -- URL of remote resource and optional headers stored in an import
  | Remote URL
  -- Environment variable
  | Env String
  | Missing

derive instance eqImportType :: Eq ImportType
derive instance ordImportType :: Ord ImportType

parent :: File
parent = File { directory: Directory (pure ".."), file: "" }

getHeaders :: ImportType -> Maybe Headers
getHeaders (Remote (URL { headers })) = headers
getHeaders _ = Nothing

isLocal :: ImportType -> Boolean
isLocal (Remote _) = false
isLocal (Local _ _) = true
isLocal (Env _) = true
isLocal Missing = false -- TODO

instance semigroupImportType :: Semigroup ImportType where
  append (Local prefix file₀) (Local Here file₁) =
    Local prefix (file₀ <> file₁)

  append (Remote (URL url)) (Local Here path) =
    Remote (URL (url { path = url.path <> path }))

  append (Local prefix file₀) (Local Parent file₁) =
    Local prefix (file₀ <> parent <> file₁)

  append (Remote (URL url)) (Local Parent path) =
    Remote (URL (url { path = url.path <> parent <> path }))

  append _ import₁ =
    import₁

parseImportType :: String -> ImportType
parseImportType "missing" = Missing
parseImportType input
  | Just env <- String.stripPrefix (String.Pattern "env:") input = Env env
  | Just url <- parseURL input = Remote url
  | otherwise = parseLocal input

parseLocal :: String -> ImportType
parseLocal "" = Missing
parseLocal input =
  let
    parts = String.split (String.Pattern "/") input
  in case Array.uncons parts of
    Just { head, tail } | Just pre <- parseFilePrefix head
      -> Local pre (mkFile tail)
    _ -> Local Here (mkFile parts)

prettyImportType :: ImportType -> String
prettyImportType (Env env) = "env:" <> env
prettyImportType Missing = "missing"
prettyImportType (Local prefix file) =
  prettyFilePrefix prefix <> prettyFile file
prettyImportType (Remote u@(URL url)) =
      prettyURL u
  <>  foldMap prettyHeaders url.headers
  where
    prettyHeaders h =
      " using " <> "[ " <> intercalate "," (prettyHeader <$> h) <> " ]"
    prettyHeader { header, value } =
      "{ mapKey = " <> show header <> ", mapValue = " <> show value <> " }"

canonicalizeImportType :: ImportType -> ImportType
canonicalizeImportType (Local prefix file) =
  Local prefix (canonicalizeFile file)
canonicalizeImportType (Remote (URL url)) =
  Remote (URL url { path = canonicalizeFile url.path })
canonicalizeImportType (Env env) = Env env
canonicalizeImportType Missing = Missing

-- | How to interpret the import's contents (i.e. as Dhall code or raw text)
data ImportMode = Code | RawText | Location

derive instance eqImportMode :: Eq ImportMode
derive instance ordImportMode :: Ord ImportMode

-- | Reference to an external resource
newtype Import = Import
  { importType :: ImportType
  , importMode :: ImportMode
  }

derive instance eqImport :: Eq Import
derive instance ordImport :: Ord Import

instance semigroupImport :: Semigroup Import where
  append (Import i0) (Import i1) = Import
    { importType: i0.importType <> i1.importType
    , importMode: i1.importMode
    }

instance showImport :: Show Import where
  show = prettyImport

prettyImport :: Import -> String
prettyImport (Import { importType, importMode }) =
  prettyImportType importType <> suffix
      where
        suffix :: String
        suffix = case importMode of
            RawText -> " as Text"
            Location -> " as Location"
            Code    -> ""

canonicalizeImport :: Import -> Import
canonicalizeImport (Import i) =
  Import i { importType = canonicalizeImportType i.importType }

previewOrigin :: ImportType -> Maybe String
previewOrigin (Remote (URL { scheme, authority })) = Just
  if String.contains (String.Pattern ":") authority
    then authority else authority <> ":" <> defaultPort
  where
    defaultPort = case scheme of
      HTTP -> "80"
      HTTPS -> "443"
previewOrigin _ = Nothing

type Header = { header :: String, value :: String }
type Headers = Array Header

getHeader :: String -> Headers -> Array String
getHeader header = Array.mapMaybe \r ->
  if String.toLower r.header == String.toLower header
    then Just r.value else Nothing

firstHeaders :: Headers -> Headers -> Headers
firstHeaders l r = l <>
  Array.filter (\{ header } -> isNothing $ Array.find (_.header >>> eq header) l) r

addHeaders :: Headers -> Import -> Import
addHeaders headers = case _ of
  Import { importMode, importType: Remote (URL url) } ->
    let url' = url { headers = Just $ firstHeaders headers (fromMaybe [] url.headers) } in
    Import { importMode, importType: Remote (URL url') }
  i -> i
