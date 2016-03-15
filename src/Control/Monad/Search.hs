{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# LANGUAGE FunctionalDependencies     #-}

-- | The Search monad and SearchT monad transformer allow computations
-- to be associated with costs and cost estimates, and explore
-- possible solutions in order of overall cost.  The solution space is
-- explored using the A* algorithm, or Dijkstra's if estimates are
-- omitted.  The order of exploring computations with equal cost is
-- not defined.
--
-- Costs must be monotonic (i.e. positive) and underestimated.  If the
-- cost of a computation is overestimated or a negative cost is
-- applied, sub-optimal solutions may be produced first.
--
-- Example:
--
-- > import Control.Monad.Search
-- > import Data.Monoid (Sum(..))
-- >
-- > -- All naturals, weighted by the size of the number
-- > naturals :: Search (Sum Integer) Integer
-- > naturals = return 0 <|> (cost' (Sum 1) >> ((+ 1) <$> naturals))
-- >   -- [ 0, 1, 2, 3, 4, 5, ... ]
-- >
-- > -- All pairs of naturals
-- > pairs :: Search (Sum Integer) (Integer, Integer)
-- > pairs = (,) <$> naturals <*> naturals
-- >   --    [ (0, 0), (1, 0), (0, 1), (1, 1), (2, 0), ... ]
-- >   -- or [ (0, 0), (0, 1), (1, 0), (2, 0), (1, 1), ... ]
-- >   -- or ...
module Control.Monad.Search
    ( -- * The Search monad
      Search
    , runSearch
      -- * The SearchT monad transformer
    , SearchT
    , runSearchT
      -- * MonadClass and search monad operations
    , MonadSearch
    , cost
    , cost'
    , junction
    , abandon
    ) where

import           Control.Applicative         ( Alternative(..) )
import           Control.Monad               ( MonadPlus(..) )
import           Control.Monad.Trans.Free    ( FreeF(Free, Pure), FreeT
                                             , runFreeT, wrap )
import           Control.Monad.Trans.State   ( evalStateT, gets, modify )

import           Control.Monad.Trans.Class   ( MonadTrans, lift )
import           Control.Monad.IO.Class      ( MonadIO )
import           Control.Monad.Reader        ( MonadReader, ReaderT(..)
                                             , runReaderT )
import qualified Control.Monad.Writer.Lazy   as Lazy ( MonadWriter, WriterT(..)
                                                     , runWriterT )
import qualified Control.Monad.Writer.Strict as Strict ( WriterT(..)
                                                       , runWriterT )
import qualified Control.Monad.State.Lazy    as Lazy ( MonadState, StateT(..)
                                                     , runStateT )
import qualified Control.Monad.State.Strict  as Strict ( StateT(..), runStateT )
import qualified Control.Monad.RWS.Lazy      as Lazy ( MonadRWS, RWST(..)
                                                     , runRWST )
import qualified Control.Monad.RWS.Strict    as Strict ( RWST(..), runRWST )
import           Control.Monad.Except        ( ExceptT(..), MonadError
                                             , runExceptT )
import           Control.Monad.Cont          ( MonadCont )
import           Data.Functor.Identity       ( Identity, runIdentity )
import           Data.Maybe                  ( catMaybes )

import qualified Data.OrdPSQ                 as PSQ

-- | The Search monad
type Search c = SearchT c Identity

-- | Generate all solutions in order of increasing cost.
runSearch :: (Ord c, Monoid c) => Search c a -> [(c, a)]
runSearch = runIdentity . runSearchT

-- | Functor for the Free monad SearchT
data SearchF c a = Cost c c a
                 | Alt a a
                 | Abandon
    deriving Functor

-- | The SearchT monad transformer
newtype SearchT c m a = SearchT { unSearchT :: FreeT (SearchF c) m a }
    deriving (Functor, Applicative, Monad, MonadTrans, MonadIO, MonadReader r, Lazy.MonadWriter w, Lazy.MonadState s, MonadError e, MonadCont)

instance (Ord c, Monoid c, Monad m) => Alternative (SearchT c m) where
    empty = abandon
    (<|>) = junction

instance (Ord c, Monoid c, Monad m) => MonadPlus (SearchT c m)

deriving instance Lazy.MonadRWS r w s m => Lazy.MonadRWS r w s (SearchT c m)

-- | Value type for A*/Dijkstra priority queue
data Cand c m a = Cand { candCost :: !c
                       , candPath :: FreeT (SearchF c) m a
                       }

-- | State used during evaluation of SearchT
data St c m a = St { stNum   :: !Int
                   , stQueue :: !(PSQ.OrdPSQ Int c (Cand c m a))
                   }

-- | Generate all solutions in order of increasing cost.
runSearchT :: (Ord c, Monoid c, Monad m) => SearchT c m a -> m [(c, a)]
runSearchT m = catMaybes <$> evalStateT go state
  where
    go = do
        mmin <- gets (PSQ.minView . stQueue)
        case mmin of
            Nothing -> return []
            Just (num, prio, cand, q) -> do
                updateQueue $ const q
                (:) <$> step num prio cand <*> go

    step num prio cand@Cand{..} = do
        path' <- lift $ runFreeT candPath
        case path' of
            Pure a -> return $ Just (candCost, a)
            Free Abandon -> return Nothing
            Free (Cost c e p) ->
                let newCost = candCost `mappend` c
                    newPriority = newCost `mappend` e
                in do
                    updateQueue $
                        PSQ.insert num
                                   newPriority
                                   cand { candCost = newCost, candPath = p }
                    return Nothing
            Free (Alt lhs rhs) -> do
                num' <- nextNum
                updateQueue $ PSQ.insert num' prio cand { candPath = rhs }
                step num prio cand { candPath = lhs }

    nextNum = do
        modify $ \s -> s { stNum = stNum s + 1 }
        gets stNum

    updateQueue f = modify $ \s -> s { stQueue = f (stQueue s) }

    state = St 0 queue

    queue = PSQ.singleton 0 mempty (Cand mempty (unSearchT m))

-- | Minimal definition is @cost@, @junction@, and @abandon@.
class (Ord c, Monoid c, Monad m) => MonadSearch c m | m -> c where
    -- | Mark a computation with a definitive cost and additional
    -- estimated cost.  Definitive costs are accumulated and reported,
    -- while the estimate is reset with every call to `cost` and will
    -- not be included in the final result.
    cost :: c -> c -> m ()

    -- | Introduce an alternative computational path to be evaluated
    -- concurrently.
    junction :: m a -> m a -> m a

    -- | Abandon a computation.
    abandon :: m a

instance (Ord c, Monoid c, Monad m) => MonadSearch c (SearchT c m) where
    cost c e = SearchT . wrap $ Cost c e (return ())
    junction lhs rhs = SearchT . wrap $ Alt (unSearchT lhs) (unSearchT rhs)
    abandon = SearchT . wrap $ Abandon

instance MonadSearch c m => MonadSearch c (ReaderT r m) where
    cost c e = lift $ cost c e
    junction lhs rhs = ReaderT $
        \r -> junction (runReaderT lhs r) (runReaderT rhs r)
    abandon = lift abandon

instance (Monoid w, MonadSearch c m) => MonadSearch c (Lazy.WriterT w m) where
    cost c e = lift $ cost c e
    junction lhs rhs = Lazy.WriterT $
        junction (Lazy.runWriterT lhs) (Lazy.runWriterT rhs)
    abandon = lift abandon

instance (Monoid w, MonadSearch c m) => MonadSearch c (Strict.WriterT w m) where
    cost c e = lift $ cost c e
    junction lhs rhs = Strict.WriterT $
        junction (Strict.runWriterT lhs) (Strict.runWriterT rhs)
    abandon = lift abandon

instance MonadSearch c m => MonadSearch c (Lazy.StateT s m) where
    cost c e = lift $ cost c e
    junction lhs rhs = Lazy.StateT $
        \s -> junction (Lazy.runStateT lhs s) (Lazy.runStateT rhs s)
    abandon = lift abandon

instance MonadSearch c m => MonadSearch c (Strict.StateT s m) where
    cost c e = lift $ cost c e
    junction lhs rhs = Strict.StateT $
        \s -> junction (Strict.runStateT lhs s) (Strict.runStateT rhs s)
    abandon = lift abandon

instance (Monoid w, MonadSearch c m) => MonadSearch c (Lazy.RWST r w s m) where
    cost c e = lift $ cost c e
    junction lhs rhs = Lazy.RWST $
        \r s -> junction (Lazy.runRWST lhs r s) (Lazy.runRWST rhs r s)
    abandon = lift abandon

instance (Monoid w, MonadSearch c m) => MonadSearch c (Strict.RWST r w s m) where
    cost c e = lift $ cost c e
    junction lhs rhs = Strict.RWST $
        \r s -> junction (Strict.runRWST lhs r s) (Strict.runRWST rhs r s)
    abandon = lift abandon

instance MonadSearch c m => MonadSearch c (ExceptT e m) where
    cost c e = lift $ cost c e
    junction lhs rhs = ExceptT $ junction (runExceptT lhs) (runExceptT rhs)
    abandon = lift abandon

-- | Mark an operation with a cost.
--
-- > cost' c = cost c mempty
cost' :: MonadSearch c m => c -> m ()
cost' c = cost c mempty
