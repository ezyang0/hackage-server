{-# LANGUAGE DeriveDataTypeable, TypeFamilies, TemplateHaskell #-}

module Distribution.Server.Features.Core.State where

import Distribution.Package
import Distribution.Server.Packages.PackageIndex (PackageIndex)
import qualified Distribution.Server.Packages.PackageIndex as PackageIndex
import Distribution.Server.Packages.Types (PkgInfo(..), pkgUploadUser, pkgUploadTime)
import Distribution.Server.Users.Types (UserId)

import Data.Acid     (Query, Update, makeAcidic)
import Data.SafeCopy (base, deriveSafeCopy)
import Data.Typeable
import Control.Monad.Reader
import qualified Control.Monad.State as State
import Data.Monoid
import Data.Time (UTCTime)
import Data.List (sortBy)
import Data.Ord (comparing)


---------------------------------- Index of metadata and tarballs
data PackagesState = PackagesState {
    packageList  :: !(PackageIndex PkgInfo)
  }
  deriving (Eq, Typeable, Show)

deriveSafeCopy 0 'base ''PackagesState

initialPackagesState :: PackagesState
initialPackagesState = PackagesState {
    packageList = mempty
  }

insertPkgIfAbsent :: PkgInfo -> Update PackagesState Bool
insertPkgIfAbsent pkg = do
    pkgsState <- State.get
    case PackageIndex.lookupPackageId (packageList pkgsState) (packageId pkg) of
        Nothing -> do State.put $ pkgsState { packageList = PackageIndex.insert pkg (packageList pkgsState) }
                      return True
        Just{}  -> do return False

-- could also return something to indicate existence
mergePkg :: PkgInfo -> Update PackagesState ()
mergePkg pkg = State.modify $ \pkgsState -> pkgsState { packageList = PackageIndex.insertWith mergeFunc pkg (packageList pkgsState) }
  where
    mergeFunc newPkg oldPkg = oldPkg {
        pkgData = pkgData newPkg,
        pkgTarball = sortByDate $ pkgTarball newPkg ++ pkgTarball oldPkg,
        -- the old package data paired with when and by whom it was replaced
        pkgDataOld = sortByDate $ (pkgData oldPkg, pkgUploadData newPkg):(pkgDataOld oldPkg ++ pkgDataOld newPkg)
      }

    sortByDate :: Ord a => [(a1, (a, b))] -> [(a1, (a, b))]
    sortByDate xs = sortBy (comparing (fst . snd)) xs

deletePackageVersion :: PackageId -> Update PackagesState ()
deletePackageVersion pkg = State.modify $ \pkgsState -> pkgsState { packageList = deleteVersion (packageList pkgsState) }
    where deleteVersion = PackageIndex.deletePackageId pkg

replacePackageUploader :: PackageId -> UserId -> Update PackagesState (Maybe String)
replacePackageUploader pkg uid = modifyPkgInfo pkg $ \pkgInfo -> pkgInfo { pkgUploadData = (pkgUploadTime pkgInfo, uid) }

replacePackageUploadTime :: PackageId -> UTCTime -> Update PackagesState (Maybe String)
replacePackageUploadTime pkg time = modifyPkgInfo pkg $ \pkgInfo -> pkgInfo { pkgUploadData = (time, pkgUploadUser pkgInfo) }

modifyPkgInfo :: PackageId -> (PkgInfo -> PkgInfo) -> Update PackagesState (Maybe String)
modifyPkgInfo pkg f = do
  pkgsState <- State.get
  case PackageIndex.lookupPackageId (packageList pkgsState) pkg of
    Nothing -> return (Just "No such package")
    Just pkgInfo -> do
      State.put $ pkgsState { packageList = PackageIndex.insert (f pkgInfo) (packageList pkgsState) }
      return Nothing

-- |Replace all existing packages and reports
replacePackagesState :: PackagesState -> Update PackagesState ()
replacePackagesState = State.put

getPackagesState :: Query PackagesState PackagesState
getPackagesState = ask

makeAcidic ''PackagesState ['getPackagesState
                           ,'replacePackagesState
                           ,'replacePackageUploadTime
                           ,'replacePackageUploader
                           ,'insertPkgIfAbsent
                           ,'mergePkg
                           ,'deletePackageVersion
                           ]

