{-# LANGUAGE ScopedTypeVariables, DeriveDataTypeable, OverloadedStrings,
             FlexibleInstances, FlexibleContexts, IncoherentInstances,
             TypeFamilies, ExistentialQuantification, RankNTypes #-}

-- | A module for shell-like programming in Haskell.
-- Shelly's focus is entirely on ease of use for those coming from shell scripting.
-- However, it also tries to use modern libraries and techniques to keep things efficient.
--
-- The functionality provided by
-- this module is (unlike standard Haskell filesystem functionality)
-- thread-safe: each Sh maintains its own environment and its own working
-- directory.
--
-- Recommended usage includes putting the following at the top of your program,
-- otherwise you will likely need either type annotations or type conversions
--
-- > {-# LANGUAGE OverloadedStrings #-}
-- > {-# LANGUAGE ExtendedDefaultRules #-}
-- > {-# OPTIONS_GHC -fno-warn-type-defaults #-}
-- > import Shelly
-- > import qualified Data.Text as T
-- > default (T.Text)
module Shelly.Lifted
       (
         MonadSh(..),

         -- This is copied from Shelly.hs, so that we are sure to export the
         -- exact same set of symbols.  Whenever that export list is updated,
         -- please make the same updates here and implements the corresponding
         -- lifted functions.

         -- * Entering Sh.
         Sh, ShIO, S.shelly, S.shellyNoDir, S.shellyFailDir, sub
         , silently, verbosely, escaping, print_stdout, print_stderr, print_commands
         , tracing, errExit

         -- * Running external commands.
         , run, run_, runFoldLines, S.cmd, S.FoldCallback
         , (-|-), lastStderr, setStdin, lastExitCode
         , command, command_, command1, command1_
         , sshPairs, sshPairs_
         , S.ShellCmd(..), S.CmdArg (..)

         -- * Running commands Using handles
         , runHandle, runHandles, transferLinesAndCombine, S.transferFoldHandleLines
         , S.StdHandle(..), S.StdStream(..)


         -- * Modifying and querying environment.
         , setenv, get_env, get_env_text, getenv, get_env_def, get_env_all, get_environment, appendToPath

         -- * Environment directory
         , cd, chdir, pwd

         -- * Printing
         , echo, echo_n, echo_err, echo_n_err, inspect, inspect_err
         , tag, trace, S.show_command

         -- * Querying filesystem.
         , ls, lsT, test_e, test_f, test_d, test_s, test_px, which

         -- * Filename helpers
         , absPath, (S.</>), (S.<.>), canonic, canonicalize, relPath, relativeTo, path
         , S.hasExt

         -- * Manipulating filesystem.
         , mv, rm, rm_f, rm_rf, cp, cp_r, mkdir, mkdir_p, mkdirTree

         -- * reading/writing Files
         , readfile, readBinary, writefile, appendfile, touchfile, withTmpDir

         -- * exiting the program
         , exit, errorExit, quietExit, terror

         -- * Exceptions
         , bracket_sh, catchany, catch_sh, handle_sh, handleany_sh, finally_sh, S.ShellyHandler(..), S.catches_sh, catchany_sh

         -- * convert between Text and FilePath
         , S.toTextIgnore, toTextWarn, FP.fromText

         -- * Utility Functions
         , S.whenM, S.unlessM, time, sleep

         -- * Re-exported for your convenience
         , liftIO, S.when, S.unless, FilePath, (S.<$>)

         -- * internal functions for writing extensions
         , Shelly.Lifted.get, Shelly.Lifted.put

         -- * find functions
         , S.find, S.findWhen, S.findFold, S.findDirFilter, S.findDirFilterWhen, S.findFoldDirFilter
         ) where

import qualified Shelly as S
import Shelly.Base (Sh(..), ShIO, Text, (>=>), FilePath)
import qualified Shelly.Base as S
import Control.Monad ( liftM )
import Prelude hiding ( FilePath )
import Data.ByteString ( ByteString )
import Data.Monoid
import System.IO ( Handle )
import Data.Tree ( Tree )
import qualified Filesystem.Path.CurrentOS as FP

import Control.Exception.Lifted
import Control.Monad.IO.Class
import Control.Monad.Trans.Control
import Control.Monad.Trans.Identity
import Control.Monad.Trans.List
import Control.Monad.Trans.Maybe
import Control.Monad.Trans.Cont
import Control.Monad.Trans.Error
import Control.Monad.Trans.Reader
import Control.Monad.Trans.State
import qualified Control.Monad.Trans.State.Strict as Strict
import Control.Monad.Trans.Writer
import qualified Control.Monad.Trans.Writer.Strict as Strict
import qualified Control.Monad.Trans.RWS as RWS
import qualified Control.Monad.Trans.RWS.Strict as Strict

class Monad m => MonadSh m where
    liftSh :: Sh a -> m a

instance MonadSh Sh where
    liftSh = id

instance MonadSh m => MonadSh (IdentityT m) where
    liftSh = IdentityT . liftSh
instance MonadSh m => MonadSh (ListT m) where
    liftSh m = ListT $ do
        a <- liftSh m
        return [a]
instance MonadSh m => MonadSh (MaybeT m) where
    liftSh = MaybeT . liftM Just . liftSh
instance MonadSh m => MonadSh (ContT r m) where
    liftSh m = ContT (liftSh m >>=)
instance (Error e, MonadSh m) => MonadSh (ErrorT e m) where
    liftSh m = ErrorT $ do
        a <- liftSh m
        return (Right a)
instance MonadSh m => MonadSh (ReaderT r m) where
    liftSh = ReaderT . const . liftSh
instance MonadSh m => MonadSh (StateT s m) where
    liftSh m = StateT $ \s -> do
        a <- liftSh m
        return (a, s)
instance MonadSh m => MonadSh (Strict.StateT s m) where
    liftSh m = Strict.StateT $ \s -> do
        a <- liftSh m
        return (a, s)
instance (Monoid w, MonadSh m) => MonadSh (WriterT w m) where
    liftSh m = WriterT $ do
        a <- liftSh m
        return (a, mempty)
instance (Monoid w, MonadSh m) => MonadSh (Strict.WriterT w m) where
    liftSh m = Strict.WriterT $ do
        a <- liftSh m
        return (a, mempty)
instance (Monoid w, MonadSh m) => MonadSh (RWS.RWST r w s m) where
    liftSh m = RWS.RWST $ \_ s -> do
        a <- liftSh m
        return (a, s, mempty)
instance (Monoid w, MonadSh m) => MonadSh (Strict.RWST r w s m) where
    liftSh m = Strict.RWST $ \_ s -> do
        a <- liftSh m
        return (a, s, mempty)

instance MonadSh m => S.ShellCmd (m Text) where
    cmdAll = (liftSh .) . S.run

instance (MonadSh m, s ~ Text, Show s) => S.ShellCmd (m s) where
    cmdAll = (liftSh .) . S.run

instance MonadSh m => S.ShellCmd (m ()) where
    cmdAll = (liftSh .) . S.run_

class Monad m => MonadShControl m where
    data ShM m a :: *
    liftShWith :: ((forall x. m x -> Sh (ShM m x)) -> Sh a) -> m a
    restoreSh :: ShM m a -> m a

instance MonadShControl Sh where
     newtype ShM Sh a = ShSh a
     liftShWith f = f $ liftM ShSh
     restoreSh (ShSh x) = return x
     {-# INLINE liftShWith #-}
     {-# INLINE restoreSh #-}

instance MonadShControl m => MonadShControl (ListT m) where
    newtype ShM (ListT m) a = ListTShM (ShM m [a])
    liftShWith f =
        ListT $ liftM (:[]) $ liftShWith $ \runInSh -> f $ \k ->
            liftM ListTShM $ runInSh $ runListT k
    restoreSh (ListTShM m) = ListT . restoreSh $ m
    {-# INLINE liftShWith #-}
    {-# INLINE restoreSh #-}

instance MonadShControl m => MonadShControl (MaybeT m) where
    newtype ShM (MaybeT m) a = MaybeTShM (ShM m (Maybe a))
    liftShWith f =
        MaybeT $ liftM Just $ liftShWith $ \runInSh -> f $ \k ->
            liftM MaybeTShM $ runInSh $ runMaybeT k
    restoreSh (MaybeTShM m) = MaybeT . restoreSh $ m
    {-# INLINE liftShWith #-}
    {-# INLINE restoreSh #-}

-- instance MonadShControl m
--          => MonadShControl (IdentityT m) where
--     newtype ShM (IdentityT m) a = IdentityTShM (ShM m a)
--     liftShWith f =
--         IdentityT $ defaultLiftShWith f runIdentityT IdentityTShM id
--     restoreSh (IdentityTShM m) = IdentityT . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

-- instance (MonadShControl m, Monoid w)
--          => MonadShControl (WriterT w m) where
--     newtype ShM (WriterT w m) a = WriterTShM (ShM m   (a, w))
--     liftShWith f = WriterT $
--         defaultLiftShWith f runWriterT WriterTShM (\x -> (x, mempty))
--     restoreSh (WriterTShM m) = WriterT . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

-- instance (MonadShControl m, Monoid w)
--          => MonadShControl (Strict.WriterT w m) where
--     newtype ShM (Strict.WriterT w m) a = StWriterTShM (ShM m (a, w))
--     liftShWith f = Strict.WriterT $
--         defaultLiftShWith f Strict.runWriterT StWriterTShM (\x -> (x, mempty))
--     restoreSh (StWriterTShM m) = Strict.WriterT . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

-- instance (MonadShControl m, Error e)
--          => MonadShControl (ErrorT e m) where
--     newtype ShM (ErrorT e m) a = ErrorTShM (ShM m (Either e a))
--     liftShWith f = ErrorT $ defaultLiftShWith f runErrorT ErrorTShM return
--     restoreSh (ErrorTShM m) = ErrorT . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

-- instance MonadShControl m => MonadShControl (StateT s m) where
--     newtype ShM (StateT s m) a = StateTShM (ShM m (a, s))
--     liftShWith f = StateT $ \s ->
--         defaultLiftShWith f (`runStateT` s) StateTShM (\x -> (x,s))
--     restoreSh (StateTShM m) = StateT . const . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

-- instance MonadShControl m => MonadShControl (Strict.StateT s m) where
--     newtype ShM (Strict.StateT s m) a = StStateTShM (ShM m (a, s))
--     liftShWith f = Strict.StateT $ \s ->
--         defaultLiftShWith f (`Strict.runStateT` s) StStateTShM (\x -> (x,s))
--     restoreSh (StStateTShM m) = Strict.StateT . const . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

-- instance MonadShControl m => MonadShControl (ReaderT r m) where
--     newtype ShM (ReaderT r m) a = ReaderTShM (ShM m a)
--     liftShWith f = ReaderT $ \r ->
--         defaultLiftShWith f (`runReaderT` r) ReaderTShM id
--     restoreSh (ReaderTShM m) = ReaderT . const . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

-- instance (MonadShControl m, Monoid w)
--          => MonadShControl (RWS.RWST r w s m) where
--     newtype ShM (RWS.RWST r w s m) a = RWSTShM (ShM m (a, s ,w))
--     liftShWith f = RWS.RWST $ \r s ->
--         defaultLiftShWith f (flip (`RWS.runRWST` r) s) RWSTShM
--             (\x -> (x,s,mempty))
--     restoreSh (RWSTShM m) = RWS.RWST . const . const . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

-- instance (MonadShControl m, Monoid w)
--          => MonadShControl (Strict.RWST r w s m) where
--     newtype ShM (Strict.RWST r w s m) a = StRWSTShM (ShM m (a, s, w))
--     liftShWith f = Strict.RWST $ \r s ->
--         defaultLiftShWith f (flip (`Strict.runRWST` r) s) StRWSTShM
--             (\x -> (x,s,mempty))
--     restoreSh (StRWSTShM m) = Strict.RWST . const . const . restoreSh $ m
--     {-# INLINE liftShWith #-}
--     {-# INLINE restoreSh #-}

controlSh :: MonadShControl m => ((forall x. m x -> Sh (ShM m x)) -> Sh (ShM m a)) -> m a
controlSh = liftShWith >=> restoreSh
{-# INLINE controlSh #-}

tag :: (MonadShControl m, MonadSh m) => m a -> Text -> m a
tag action msg = controlSh $ \runInSh -> S.tag (runInSh action) msg

chdir :: MonadShControl m => FilePath -> m a -> m a
chdir dir action = controlSh $ \runInSh -> S.chdir dir (runInSh action)

silently :: MonadShControl m => m a -> m a
silently a = controlSh $ \runInSh -> S.silently (runInSh a)

verbosely :: MonadShControl m => m a -> m a
verbosely a = controlSh $ \runInSh -> S.verbosely (runInSh a)

print_stdout :: MonadShControl m => Bool -> m a -> m a
print_stdout shouldPrint a = controlSh $ \runInSh -> S.print_stdout shouldPrint (runInSh a)

print_stderr :: MonadShControl m => Bool -> m a -> m a
print_stderr shouldPrint a = controlSh $ \runInSh -> S.print_stderr shouldPrint (runInSh a)

print_commands :: MonadShControl m => Bool -> m a -> m a
print_commands shouldPrint a = controlSh $ \runInSh -> S.print_commands shouldPrint (runInSh a)

sub :: MonadShControl m => m a -> m a
sub a = controlSh $ \runInSh -> S.sub (runInSh a)

trace :: MonadSh m => Text -> m ()
trace = liftSh . S.trace

tracing :: MonadShControl m => Bool -> m a -> m a
tracing shouldTrace action = controlSh $ \runInSh -> S.tracing shouldTrace (runInSh action)

escaping :: MonadShControl m => Bool -> m a -> m a
escaping shouldEscape action = controlSh $ \runInSh -> S.escaping shouldEscape (runInSh action)

errExit :: MonadShControl m => Bool -> m a -> m a
errExit shouldExit action = controlSh $ \runInSh -> S.errExit shouldExit (runInSh action)

(-|-) :: (MonadShControl m, MonadSh m) => m Text -> m b -> m b
one -|- two = controlSh $ \runInSh -> do
    x <- runInSh one
    runInSh $ restoreSh x >>= \x' ->
        controlSh $ \runInSh' -> return x' S.-|- runInSh' two

withTmpDir :: MonadShControl m => (FilePath -> m a) -> m a
withTmpDir action = controlSh $ \runInSh -> S.withTmpDir (fmap runInSh action)

time :: MonadShControl m => m a -> m (Double, a)
time what = controlSh $ \runInSh -> do
    (d, a) <- S.time (runInSh what)
    runInSh $ restoreSh a >>= \x -> return (d, x)

toTextWarn :: MonadSh m => FilePath -> m Text
toTextWarn = liftSh . toTextWarn

transferLinesAndCombine :: MonadIO m => Handle -> Handle -> m Text
transferLinesAndCombine = (liftIO .) . S.transferLinesAndCombine

get :: MonadSh m => m S.State
get = liftSh S.get

gets :: MonadSh m => (S.State -> a) -> m a
gets = liftSh . S.gets

modify :: MonadSh m => (S.State -> S.State) -> m ()
modify = liftSh . S.modify

put :: MonadSh m => S.State -> m ()
put = liftSh . S.put

catch_sh :: (Exception e) => Sh a -> (e -> Sh a) -> Sh a
catch_sh = catch

handle_sh :: (Exception e) => (e -> Sh a) -> Sh a -> Sh a
handle_sh = handle

finally_sh :: Sh a -> Sh b -> Sh a
finally_sh = finally

bracket_sh :: Sh a -> (a -> Sh b) -> (a -> Sh c) -> Sh c
bracket_sh = bracket

-- catches_sh :: Sh a -> [ShellyHandler a] -> Sh a
-- catches_sh = catches

catchany_sh :: Sh a -> (SomeException -> Sh a) -> Sh a
catchany_sh = catch

handleany_sh :: (SomeException -> Sh a) -> Sh a -> Sh a
handleany_sh = handle

cd :: MonadSh m => FilePath -> m ()
cd = liftSh . S.cd

mv :: MonadSh m => FilePath -> FilePath -> m ()
mv = (liftSh .) . S.mv

lsT :: MonadSh m => FilePath -> m [Text]
lsT = liftSh . S.lsT

pwd :: MonadSh m => m FilePath
pwd = liftSh S.pwd

exit :: MonadSh m => Int -> m a
exit = liftSh . S.exit

errorExit :: MonadSh m => Text -> m a
errorExit = liftSh . S.errorExit

quietExit :: MonadSh m => Int -> m a
quietExit = liftSh . S.quietExit

terror :: MonadSh m => Text -> m a
terror = liftSh . S.terror

mkdir :: MonadSh m => FilePath -> m ()
mkdir = liftSh . S.mkdir

mkdir_p :: MonadSh m => FilePath -> m ()
mkdir_p = liftSh . S.mkdir_p

mkdirTree :: MonadSh m => Tree FilePath -> m ()
mkdirTree = liftSh . S.mkdirTree

which :: MonadSh m => FilePath -> m (Maybe FilePath)
which = liftSh . S.which

test_e :: MonadSh m => FilePath -> m Bool
test_e = liftSh . S.test_e

test_f :: MonadSh m => FilePath -> m Bool
test_f = liftSh . S.test_f

test_px :: MonadSh m => FilePath -> m Bool
test_px = liftSh . S.test_px

rm_rf :: MonadSh m => FilePath -> m ()
rm_rf = liftSh . S.rm_rf

rm_f :: MonadSh m => FilePath -> m ()
rm_f = liftSh . S.rm_f

rm :: MonadSh m => FilePath -> m ()
rm = liftSh . S.rm

setenv :: MonadSh m => Text -> Text -> m ()
setenv = (liftSh .) . S.setenv

appendToPath :: MonadSh m => FilePath -> m ()
appendToPath = liftSh . S.appendToPath

get_environment :: MonadSh m => m [(String, String)]
get_environment = liftSh S.get_environment

get_env_all :: MonadSh m => m [(String, String)]
get_env_all = liftSh S.get_env_all

get_env :: MonadSh m => Text -> m (Maybe Text)
get_env = liftSh . S.get_env

getenv :: MonadSh m => Text -> m Text
getenv = liftSh . S.getenv

get_env_text :: MonadSh m => Text -> m Text
get_env_text = liftSh . S.get_env_text

get_env_def :: MonadSh m => Text -> Text -> m Text
get_env_def = (liftSh .) . S.get_env_def

sshPairs_ :: MonadSh m => Text -> [(FilePath, [Text])] -> m ()
sshPairs_ = (liftSh .) . S.sshPairs_

sshPairs :: MonadSh m => Text -> [(FilePath, [Text])] -> m Text
sshPairs = (liftSh .) . S.sshPairs

run :: MonadSh m => FilePath -> [Text] -> m Text
run = (liftSh .) . run

command :: MonadSh m => FilePath -> [Text] -> [Text] -> m Text
command com args more_args =
    liftSh $ S.command com args more_args

command_ :: MonadSh m => FilePath -> [Text] -> [Text] -> m ()
command_ com args more_args =
    liftSh $ S.command_ com args more_args

command1 :: MonadSh m => FilePath -> [Text] -> Text -> [Text] -> m Text
command1 com args one_arg more_args =
    liftSh $ S.command1 com args one_arg more_args

command1_ :: MonadSh m => FilePath -> [Text] -> Text -> [Text] -> m ()
command1_ com args one_arg more_args =
    liftSh $ S.command1_ com args one_arg more_args

run_ :: MonadSh m => FilePath -> [Text] -> m ()
run_ = (liftSh .) . S.run_

runHandle :: MonadShControl m => FilePath -- ^ command
          -> [Text] -- ^ arguments
          -> (Handle -> m a) -- ^ stdout handle
          -> m a
runHandle exe args withHandle =
    controlSh $ \runInSh -> S.runHandle exe args (fmap runInSh withHandle)

runHandles :: MonadShControl m => FilePath -- ^ command
           -> [Text] -- ^ arguments
           -> [S.StdHandle] -- ^ optionally connect process i/o handles to existing handles
           -> (Handle -> Handle -> Handle -> m a) -- ^ stdin, stdout and stderr
           -> m a
runHandles exe args reusedHandles withHandles =
    controlSh $ \runInSh ->
        S.runHandles exe args reusedHandles (fmap (fmap (fmap runInSh)) withHandles)

runFoldLines :: MonadSh m => a -> S.FoldCallback a -> FilePath -> [Text] -> m a
runFoldLines start cb exe args = liftSh $ S.runFoldLines start cb exe args

lastStderr :: MonadSh m => m Text
lastStderr = liftSh S.lastStderr

lastExitCode :: MonadSh m => m Int
lastExitCode = liftSh S.lastExitCode

setStdin :: MonadSh m => Text -> m ()
setStdin = liftSh . S.setStdin

cp_r :: MonadSh m => FilePath -> FilePath -> m ()
cp_r = (liftSh .) . S.cp_r

cp :: MonadSh m => FilePath -> FilePath -> m ()
cp = (liftSh .) . S.cp

writefile :: MonadSh m => FilePath -> Text -> m ()
writefile = (liftSh .) . S.writefile

touchfile :: MonadSh m => FilePath -> m ()
touchfile = liftSh . S.touchfile

appendfile :: MonadSh m => FilePath -> Text -> m ()
appendfile = (liftSh .) . S.appendfile

readfile :: MonadSh m => FilePath -> m Text
readfile = liftSh . S.readfile

readBinary :: MonadSh m => FilePath -> m ByteString
readBinary = liftSh . S.readBinary

sleep :: MonadSh m => Int -> m ()
sleep = liftSh . S.sleep

echo, echo_n, echo_err, echo_n_err :: MonadSh m => Text -> m ()
echo       = liftSh . S.echo
echo_n     = liftSh . S.echo_n
echo_err   = liftSh . S.echo_err
echo_n_err = liftSh . S.echo_n_err

relPath :: MonadSh m => FilePath -> m FilePath
relPath = liftSh . S.relPath

relativeTo :: MonadSh m => FilePath -- ^ anchor path, the prefix
           -> FilePath -- ^ make this relative to anchor path
           -> m FilePath
relativeTo = (liftSh .) . S.relativeTo

canonic :: MonadSh m => FilePath -> m FilePath
canonic = liftSh . canonic

-- | Obtain a (reasonably) canonic file path to a filesystem object. Based on
-- "canonicalizePath" in system-fileio.
canonicalize :: MonadSh m => FilePath -> m FilePath
canonicalize = liftSh . S.canonicalize

absPath :: MonadSh m => FilePath -> m FilePath
absPath = liftSh . S.absPath

path :: MonadSh m => FilePath -> m FilePath
path = liftSh . S.path

test_d :: MonadSh m => FilePath -> m Bool
test_d = liftSh . S.test_d

test_s :: MonadSh m => FilePath -> m Bool
test_s = liftSh . S.test_s

ls :: MonadSh m => FilePath -> m [FilePath]
ls = liftSh . S.ls

lsRelAbs :: MonadSh m => FilePath -> m ([FilePath], [FilePath])
lsRelAbs = liftSh . S.lsRelAbs

inspect :: (Show s, MonadSh m) => s -> m ()
inspect = liftSh . S.inspect

inspect_err :: (Show s, MonadSh m) => s -> m ()
inspect_err = liftSh . S.inspect_err

catchany :: MonadBaseControl IO m => m a -> (SomeException -> m a) -> m a
catchany = catch
