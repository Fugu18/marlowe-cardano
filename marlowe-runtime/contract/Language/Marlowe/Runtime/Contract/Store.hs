{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

module Language.Marlowe.Runtime.Contract.Store
  where

import Control.Monad.Event.Class
import Data.Foldable (traverse_)
import Data.Set (Set)
import Data.Void (Void)
import Language.Marlowe.Core.V1.Semantics.Types (Contract, Input, InputContent, State, TimeInterval)
import Language.Marlowe.Runtime.ChainSync.Api (DatumHash)
import Language.Marlowe.Runtime.Contract.Api (ContractWithAdjacency, MerkleizedInputsError)
import Observe.Event (InjectSelector, addField, injectSelector, reference)
import Observe.Event.Backend (setInitialCauseEventBackend)

data ContractStoreSelector f where
  CreateContractStagingArea :: ContractStoreSelector Void
  ContractStagingAreaSelector :: ContractStagingAreaSelector f -> ContractStoreSelector f
  GetContract :: DatumHash -> ContractStoreSelector ContractWithAdjacency
  MerkleizedInputs  :: ContractStoreSelector MerkleizedInputsField

data MerkleizedInputsField
  = MerkleizedInputsContractHash DatumHash
  | MerkleizedInputsState State
  | MerkleizedInputsInterval TimeInterval
  | MerkleizedInputsInputs  [InputContent]
  | MerkleizedInputsResult  (Either MerkleizedInputsError [Input])

data ContractStore m = ContractStore
  { createContractStagingArea :: m (ContractStagingArea m)
  , getContract :: DatumHash -> m (Maybe ContractWithAdjacency)
  , merkleizeInputs :: DatumHash -> State -> TimeInterval -> [InputContent] -> m (Either MerkleizedInputsError [Input])
  }

hoistContractStore
  :: Functor m
  => (forall x. m x -> n x)
  -> ContractStore m
  -> ContractStore n
hoistContractStore f ContractStore{..} = ContractStore
  { createContractStagingArea = f $ hoistContractStagingArea f <$> createContractStagingArea
  , getContract = f . getContract
  , merkleizeInputs = (fmap . fmap . fmap) f . merkleizeInputs
  }

traceContractStore
  :: (MonadEvent r s m)
  => InjectSelector ContractStoreSelector s
  -> ContractStore m
  -> ContractStore m
traceContractStore inj ContractStore{..} = ContractStore
  { createContractStagingArea = withInjectEvent inj CreateContractStagingArea \ev ->
      hoistContractStagingArea (localBackend $ setInitialCauseEventBackend [reference ev])
        . traceContractStagingArea (composeInjectSelector inj $ injectSelector ContractStagingAreaSelector)
        <$> createContractStagingArea
  , getContract = \hash -> withInjectEvent inj (GetContract hash) \ev -> do
      result <- getContract hash
      traverse_ (addField ev) result
      pure result
  , merkleizeInputs = \hash state interval inputs -> withInjectEvent inj MerkleizedInputs \ev -> do
      addField ev $ MerkleizedInputsContractHash hash
      addField ev $ MerkleizedInputsState state
      addField ev $ MerkleizedInputsInterval interval
      addField ev $ MerkleizedInputsInputs inputs
      result <- merkleizeInputs hash state interval inputs
      addField ev $ MerkleizedInputsResult result
      pure result
  }

data ContractStagingAreaSelector f where
  StageContract :: ContractStagingAreaSelector StageContractField
  Flush :: ContractStagingAreaSelector (Set DatumHash)
  Commit :: ContractStagingAreaSelector (Set DatumHash)
  Discard :: ContractStagingAreaSelector Void

data StageContractField
  = StageContractContract Contract
  | StageContractHash DatumHash

data ContractStagingArea m = ContractStagingArea
  { stageContract :: Contract -> m DatumHash
  , flush :: m (Set DatumHash)
  , commit :: m (Set DatumHash)
  , discard :: m ()
  }

hoistContractStagingArea
  :: (forall x. m x -> n x)
  -> ContractStagingArea m
  -> ContractStagingArea n
hoistContractStagingArea f ContractStagingArea{..} = ContractStagingArea
  { stageContract = f . stageContract
  , flush = f flush
  , commit = f commit
  , discard = f discard
  }

traceContractStagingArea
  :: MonadEvent r s m
  => InjectSelector ContractStagingAreaSelector s
  -> ContractStagingArea m
  -> ContractStagingArea m
traceContractStagingArea inj ContractStagingArea{..} = ContractStagingArea
  { stageContract = \contract ->
      withInjectEventFields inj StageContract [StageContractContract contract] \ev -> do
        hash <- stageContract contract
        addField ev $ StageContractHash hash
        pure hash
  , flush = withInjectEvent inj Flush \ev -> do
      flushedHashes <- flush
      addField ev flushedHashes
      pure flushedHashes
  , commit = withInjectEvent inj Commit \ev -> do
      committedHashes <- commit
      addField ev committedHashes
      pure committedHashes
  , discard = withInjectEvent inj Discard $ const discard
  }
