-----------------------------------------------------------------------------
--
-- Module      :  Ghf.Info
-- Copyright   :  (c) Juergen Nicklisch-Franken (aka Jutaro)
-- License     :  GNU-GPL
--
-- Maintainer  :  Juergen Nicklisch-Franken <jnf at arcor.de>
-- Stability   :  experimental
-- Portability :  portable
--
-- | This module provides the infos collected by the extractor before
--   and an info pane to present some of them to the user
--
---------------------------------------------------------------------------------

module Ghf.Info (
    loadAccessibleInfo
,   updateAccessibleInfo

,   clearCurrentInfo
,   buildCurrentInfo
,   buildActiveInfo

,   getIdentifierDescr
,   initInfo
,   setInfo
,   isInfo

,   getInstalledPackageInfos
,   findFittingPackages
,   findFittingPackagesDP
,   fromDPid
,   asDPid
) where

import Graphics.UI.Gtk hiding (afterToggleOverwrite)
import Graphics.UI.Gtk.SourceView
import Graphics.UI.Gtk.ModelView as New
import Graphics.UI.Gtk.Multiline.TextView
import Control.Monad.Reader
import Data.IORef
import System.IO
import qualified Data.Map as Map
import Data.Map (Map,(!))
import Config
import Control.Monad
import Control.Monad.Trans
import System.FilePath
import System.Directory
import Data.Map (Map)
import qualified Data.Map as Map
import GHC
import System.IO
import Control.Concurrent
import qualified Distribution.Package as DP
import Distribution.PackageDescription hiding (package)
--import Distribution.InstalledPackageInfo
import Distribution.Version
import Data.List
import UniqFM
import PackageConfig
import Data.Maybe

import Ghf.File
import Ghf.Core
import Ghf.SourceCandy
import Ghf.ViewFrame
import Ghf.PropertyEditor
import Ghf.SpecialEditors
import Ghf.Log

--
-- | Load all infos for all installed and exposed packages
--   (see shell command: ghc-pkg list)
--
loadAccessibleInfo :: GhfAction
loadAccessibleInfo =
    let version     =   cProjectVersion in do
        session         <-  readGhf session

        collectorPath   <-  lift $ getCollectorPath version
        packageInfos    <-  lift $ getInstalledPackageInfos session
        packageList     <-  lift $ mapM (loadInfosForPackage collectorPath)
                                                    (map package packageInfos)
        let scope       =   foldr buildScope (Map.empty,Map.empty)
                                $ map fromJust
                                    $ filter isJust packageList
        modifyGhf_ (\ghf -> return (ghf{accessibleInfo = (Just scope)}))

--
-- | Clears the current info, not the world infos
--
clearCurrentInfo :: GhfAction
clearCurrentInfo = do
    modifyGhf_ (\ghf    ->  return (ghf{currentInfo = Nothing}))

--
-- | Builds the current info for a package
--
buildCurrentInfo :: PackageDescr -> GhfAction
buildCurrentInfo pd@(PackageDescr _ _ depends _ _) = do
    active              <-  buildActiveInfo
    case active of
        Nothing -> modifyGhf_ (\ghf -> return (ghf{currentInfo = Nothing}))
        Just active -> do
            accessibleInfo      <-  readGhf accessibleInfo
            case accessibleInfo of
                Nothing         ->  modifyGhf_ (\ghf -> return (ghf{currentInfo = Nothing}))
                Just (pdmap,_)  ->  do
                    let packageList =   map (\ pi -> pi `Map.lookup` pdmap) depends
                    let scope       =   foldr buildScope (Map.empty,Map.empty)
                                            $ map fromJust
                                                $ filter isJust packageList
                    modifyGhf_ (\ghf -> return (ghf{currentInfo = Just (active, scope)}))

--
-- | Builds the current info for the activePackage
--
buildActiveInfo :: GhfM (Maybe PackageScope)
buildActiveInfo =
    let version         =   cProjectVersion in do
    activePack          <-  readGhf activePack
    log                 <-  getLog
    case activePack of
        Nothing         ->  return Nothing
        Just ghfPackage ->  do
            (inp,out,err,pid) <- lift $ runExternal "ghf-collector"
                                        (["--Uninstalled=" ++ cabalFile ghfPackage])
            oid         <-  lift $ forkIO (readOut log out)
            eid         <-  lift $ forkIO (readErr log err)
            lift $ threadDelay 3000
            collectorPath   <-  lift $ getCollectorPath version
            packageDescr    <-  lift $ loadInfosForPackage collectorPath (packageId ghfPackage)
            case packageDescr of
                Nothing     -> return Nothing
                Just pd     -> do
                    let scope       =   buildScope pd (Map.empty,Map.empty)
                    return (Just scope)

--
-- | Updates the world info (it is the responsibility of the caller to rebuild
--   the current info
--
updateAccessibleInfo :: GhfAction
updateAccessibleInfo = do
    wi              <-  readGhf accessibleInfo
    session         <-  readGhf session
    let version     =   cProjectVersion
    case wi of
        Nothing -> loadAccessibleInfo
        Just (psmap,psst) -> do
            packageInfos        <-  lift $ getInstalledPackageInfos session
            let packageIds      =   map package packageInfos
            let newPackages     =   filter (\ pi -> Map.member pi psmap) packageIds
            let trashPackages   =   filter (\ e  -> not (elem e packageIds))(Map.keys psmap)
            if null newPackages && null trashPackages
                then return ()
                else do
                    collectorPath   <-  lift $ getCollectorPath version
                    newPackageInfos <-  lift $ mapM (loadInfosForPackage collectorPath)
                                                newPackages
                    let psamp2      =   foldr (\e m -> Map.insert (packageIdW e) e m)
                                                psmap
                                                (map fromJust
                                                    $ filter isJust newPackageInfos)
                    let psamp3      =   foldr (\e m -> Map.delete e m) psmap trashPackages
                    let scope       =   foldr buildScope (Map.empty,Map.empty)
                                            (Map.elems psamp3)
                    modifyGhf_ (\ghf -> return (ghf{accessibleInfo = Just scope}))


--
-- | Loads the infos for the given packages
--
loadInfosForPackage :: FilePath -> PackageIdentifier -> IO (Maybe PackageDescr)
loadInfosForPackage dirPath pid = do
    let filePath = dirPath </> showPackageId pid ++ ".pack"
    exists <- doesFileExist filePath
    if exists
        then catch (do
            hdl <- openFile filePath ReadMode
            putStrLn $ "Now reading iface " ++ showPackageId pid
            str <- hGetContents hdl
            packageInfo <- readIO str
            hClose hdl
            return (Just packageInfo))
            (\e -> do putStrLn (show e); return Nothing)
        else do
            message $"packaeInfo not found for " ++ showPackageId pid
            return Nothing

--
-- | Loads the infos for the given packages (has an collecting argument)
--
buildScope :: PackageDescr -> PackageScope -> PackageScope
buildScope packageD (packageMap, symbolTable) =
    let pid = packageIdW packageD
    in if pid `Map.member` packageMap
        then trace  ("package already in world " ++ showPackageId (packageIdW packageD))
                    (packageMap, symbolTable)
        else (Map.insert pid packageD packageMap,
              Map.unionWith (++) symbolTable (idDescriptions packageD))

--
-- | Lookup of the identifier description
--
getIdentifierDescr :: String -> SymbolTable -> [IdentifierDescr]
getIdentifierDescr str st =
    case str `Map.lookup` st of
        Nothing -> []
        Just list -> list

{--
typeDescription :: String -> SymbolTable -> String
typeDescription str st =
    case str `Map.lookup` st of
        Nothing -> "No info found -- Testing for scoped symbols missing \n"
        Just list -> concatMap generateText list
    where
        ttString Function   =   "identifies a function of type "
        ttString Data       =   "identifies data definition"
        ttString Newtype    =   "identifies a Newtype"
        ttString Synonym    =   "identifies a synonym type for"
        ttString AbstractData = "identifies an abstract data type"
        ttString Constructor =  "identifies a constructor of data type"
        ttString Field      =   "identifies a field in a record with type"
        ttString Class      =   "identifies a class"
        ttString ClassOp    =   "identifies a class operation with type "
        ttString Foreign    =   "identifies something strange"
        generateText (IdentifierDescr _ tt ti m p) =
            str ++ " "  ++   (ttString tt) ++ "\n   "
                ++   ti ++  "\n   "
                ++   "exported by modules "  ++   show m ++ " in package " ++ show p ++ "\n   "
--}

-- ---------------------------------------------------------------------
-- The little helpers
--

getInstalledPackageInfos :: Session -> IO [InstalledPackageInfo]
getInstalledPackageInfos session = do
    dflags1         <-  getSessionDynFlags session
    pkgInfos        <-  case pkgDatabase dflags1 of
                            Nothing -> return []
                            Just fm -> return (eltsUFM fm)
    return pkgInfos

findFittingPackages :: Session -> [Dependency] -> IO  [PackageIdentifier]
findFittingPackages session dependencyList = do
    knownPackages   <-  getInstalledPackageInfos session
    let packages    =   map package knownPackages
    return (concatMap (fittingKnown packages) dependencyList)
    where
    fittingKnown packages (Dependency dname versionRange) =
        let filtered =  filter (\ (PackageIdentifier name version) ->
                                    name == dname && withinRange version versionRange)
                        packages
        in  if length filtered > 1
                then [maximumBy (\a b -> compare (pkgVersion a) (pkgVersion b)) filtered]
                else filtered

findFittingPackagesDP :: Session -> [Dependency] -> IO  [DP.PackageIdentifier]
findFittingPackagesDP session dependencyList =  do
        fp <- (findFittingPackages session dependencyList)
        return (map asDPid fp)

asDPid :: PackageIdentifier -> DP.PackageIdentifier
asDPid (PackageIdentifier name version) = DP.PackageIdentifier name version

fromDPid :: DP.PackageIdentifier -> PackageIdentifier
fromDPid (DP.PackageIdentifier name version) = PackageIdentifier name version



-- ---------------------------------------------------------------------
-- The GUI stuff for infos
--


infoPaneName = "Info"

idDescrDescr :: [FieldDescriptionE IdentifierDescr]
idDescrDescr = [
        mkFieldE (emptyParams
            {   paraName = Just "Symbol"})
            identifierW
            (\ b a -> a{identifierW = b})
            stringEditor
    ,   mkFieldE (emptyParams
            {   paraName = Just "Modules exporting"})
            moduleIdI
            (\ b a -> a{moduleIdI = b})
            (multisetEditor (ColumnDescr False [("",(\row -> [New.cellText := row]))])
                (stringEditor, emptyParams))
    ,   mkFieldE (emptyParams
            {  paraName = Just "From Package"})
            packageIdI
            (\b a -> a{packageIdI = b})
            packageEditor
    ,   mkFieldE (emptyParams
            {paraName = Just "Sort of symbol"})
            identifierType
            (\b a -> a{identifierType = b})
            (staticSelectionEditor allIdTypes)
    ,   mkFieldE (emptyParams
            {paraName = Just "Type Info"})
            typeInfo
            (\b a -> a{typeInfo = b})
            multilineStringEditor
{--    ,   mkField (emptyParams
            {paraName = Just "Documentation"})
            typeInfo
            (\b a -> a{typeInfo = b})
            multilineStringEditor--}]

allIdTypes = [Function,Data,Newtype,Synonym,AbstractData,Constructor,Field,Class,ClassOp,Foreign]

initInfo :: PanePath -> Notebook -> IdentifierDescr -> GhfAction
initInfo panePath nb idDescr = do
    ghfR <- ask
    panes <- readGhf panes
    paneMap <- readGhf paneMap
    prefs <- readGhf prefs
    (pane,cids) <- lift $ do
            nbbox       <- vBoxNew False 0
            bb          <- hButtonBoxNew
            definitionB <- buttonNewWithLabel "Definition"
            docuB       <- buttonNewWithLabel "Docu"
            usesB       <- buttonNewWithLabel "Uses"
            boxPackStart bb definitionB PackNatural 0
            boxPackStart bb docuB PackNatural 0
            boxPackStart bb usesB PackNatural 0
            resList <- mapM (\ fd -> (fieldEditor fd) idDescr) idDescrDescr
            let (widgets, setInjs, getExts, notifiers) = unzip4 resList
            mapM_ (\ w -> boxPackStart nbbox w PackNatural 0) widgets
            boxPackEnd nbbox bb PackNatural 0
            --openType
            let info = GhfInfo nbbox setInjs
            notebookPrependPage nb nbbox infoPaneName
            widgetShowAll (box info)
            return (info,[])
    let newPaneMap  =  Map.insert (uniquePaneName (InfoPane pane))
                            (panePath, BufConnections [] [] cids) paneMap
    let newPanes = Map.insert infoPaneName (InfoPane pane) panes
    modifyGhf_ (\ghf -> return (ghf{panes = newPanes,
                                    paneMap = newPaneMap}))
    lift $widgetGrabFocus (box pane)

makeInfoActive :: GhfInfo -> GhfAction
makeInfoActive info = do
    activatePane (InfoPane info) (BufConnections[][][])

setInfo :: IdentifierDescr -> GhfM ()
setInfo identifierDescr = do
    panesST <- readGhf panes
    prefs   <- readGhf prefs
    layout  <- readGhf layout
    let infos = map (\ (InfoPane b) -> b) $filter isInfo $Map.elems panesST
    if null infos || length infos > 1
        then do
            let pp  =  getStandardPanePath (infoPanePath prefs) layout
            lift $ message $ "panePath " ++ show pp
            nb      <- getNotebook pp
            initInfo pp nb identifierDescr
            panesST <- readGhf panes
            let logs = map (\ (InfoPane b) -> b) $filter isInfo $Map.elems panesST
            if null logs || length logs > 1
                then error "Can't init info"
                else return ()
        else do
            let inj = injectors (head infos)
            mapM_ (\ a -> lift $ a identifierDescr)  inj
            return ()

isInfo :: GhfPane -> Bool
isInfo (InfoPane _) = True
isInfo _            = False

