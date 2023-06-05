{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}

module Language.Marlowe.Runtime.Web.Server.TxClient
  where

import Cardano.Api (BabbageEra, Tx, TxBody, getTxId)
import Control.Concurrent.Async (concurrently_)
import Control.Concurrent.Component
import Control.Concurrent.STM
  ( STM
  , TMVar
  , TVar
  , atomically
  , modifyTVar
  , newEmptyTMVar
  , newTQueue
  , newTVar
  , putTMVar
  , readTQueue
  , readTVar
  , takeTMVar
  , writeTQueue
  )
import Control.Concurrent.STM.Delay (newDelay, waitDelay)
import Control.Exception (SomeException, try)
import Control.Monad (when, (<=<))
import Control.Monad.Event.Class
import Control.Monad.IO.Unlift (MonadUnliftIO, liftIO, withRunInIO)
import Data.Foldable (for_)
import qualified Data.Map as Map
import Data.Time (UTCTime)
import Language.Marlowe.Protocol.Client (MarloweRuntimeClient(..))
import Language.Marlowe.Runtime.Cardano.Api (fromCardanoTxId)
import Language.Marlowe.Runtime.ChainSync.Api (Lovelace, StakeCredential, TokenName, TxId)
import Language.Marlowe.Runtime.Core.Api
  (Contract, ContractId, Inputs, MarloweTransactionMetadata, MarloweVersion, MarloweVersionTag)
import Language.Marlowe.Runtime.Transaction.Api
  ( ApplyInputsError
  , ContractCreated(..)
  , CreateError
  , InputsApplied(..)
  , MarloweTxCommand(..)
  , RoleTokensConfig
  , SubmitError
  , SubmitStatus(..)
  , WalletAddresses
  , WithdrawError
  )
import Network.Protocol.Connection (SomeClientConnectorTraced)
import Network.Protocol.Driver.Trace (HasSpanContext, runSomeConnectorTraced)
import Network.Protocol.Job.Client
import Observe.Event.Backend (setAncestorEventBackend)

newtype TxClientDependencies r s m = TxClientDependencies
  { connector :: SomeClientConnectorTraced MarloweRuntimeClient r s m
  }

type CreateContract m
   = forall v
   . Maybe StakeCredential
  -> MarloweVersion v
  -> WalletAddresses
  -> RoleTokensConfig
  -> MarloweTransactionMetadata
  -> Lovelace
  -> Contract v
  -> m (Either (CreateError v) (ContractCreated BabbageEra v))

type ApplyInputs m
   = forall v
   . MarloweVersion v
  -> WalletAddresses
  -> ContractId
  -> MarloweTransactionMetadata
  -> Maybe UTCTime
  -> Maybe UTCTime
  -> Inputs v
  -> m (Either (ApplyInputsError v) (InputsApplied BabbageEra v))

type Withdraw m
   = forall v
   . MarloweVersion v
  -> WalletAddresses
  -> ContractId
  -> TokenName
  -> m (Either (WithdrawError v) (TxBody BabbageEra))

data TempTxStatus = Unsigned | Submitted

type Submit r m = r -> Submit' m

type Submit' m = Tx BabbageEra -> m (Maybe SubmitError)

newtype Withdrawn era (v :: MarloweVersionTag) = Withdrawn { unWithdrawn :: TxBody era }

data TempTx (tx :: * -> MarloweVersionTag -> *) where
  TempTx :: MarloweVersion v -> TempTxStatus -> tx BabbageEra v -> TempTx tx

-- | Public API of the TxClient
data TxClient r m = TxClient
  { createContract :: CreateContract m
  , applyInputs :: ApplyInputs m
  , withdraw :: Withdraw m
  , submitContract :: ContractId -> Submit r m
  , submitTransaction :: ContractId -> TxId -> Submit r m
  , submitWithdrawal :: TxId -> Submit r m
  , lookupTempContract :: ContractId -> STM (Maybe (TempTx ContractCreated))
  , getTempContracts :: STM [TempTx ContractCreated]
  , lookupTempTransaction :: ContractId -> TxId -> STM (Maybe (TempTx InputsApplied))
  , getTempTransactions :: ContractId -> STM [TempTx InputsApplied]
  , lookupTempWithdrawal :: TxId -> STM (Maybe (TempTx Withdrawn))
  , getTempWithdrawals :: STM [TempTx Withdrawn]
  }

-- Basically a lens to the actual map of temp txs to modify within a structure.
-- For example, tempTransactions is a (Map ContractId (Map TxId (TempTx InputsApplied))),
-- so to apply the given map modification to the inner map, we provide
-- \update -> Map.update (Just . update txId) contractId
type WithMapUpdate k tx a
   = (k -> Map.Map k (TempTx tx) -> Map.Map k (TempTx tx)) -- ^ Takes a function that, given a key in a map, modifies a map of temp txs
  -> (a -> a)                                              -- ^ And turns it into a function that modifies values of some type a

-- Pack a TVar of a's with a lens for modifying some inner map in the TVar and
-- existentialize the type parameters.
data SomeTVarWithMapUpdate = forall k tx a. Ord k => SomeTVarWithMapUpdate (TVar a) (WithMapUpdate k tx a)

txClient
  :: forall r s m
   . (MonadEvent r s m, MonadUnliftIO m, HasSpanContext r)
  => Component m (TxClientDependencies r s m) (TxClient r m)
txClient = component "web-tx-client" \TxClientDependencies{..} -> do
  tempContracts <- newTVar mempty
  tempTransactions <- newTVar mempty
  tempWithdrawals <- newTVar mempty
  submitQueue <- newTQueue

  let
    runSubmitGeneric :: SomeTVarWithMapUpdate -> Tx BabbageEra -> TMVar (Maybe SubmitError) -> m ()
    runSubmitGeneric (SomeTVarWithMapUpdate tempVar updateTemp) tx sender = do
      let
        cmd = Submit tx
        client = JobClient $ pure $ SendMsgExec cmd $ clientCmd True
        clientCmd report = ClientStCmd
          { recvMsgFail = \err -> liftIO $ atomically do
              when report $ putTMVar sender $ Just err
              modifyTVar tempVar $ updateTemp $ Map.update (Just . toUnsigned)
          , recvMsgSucceed = \_ -> liftIO $ atomically do
              modifyTVar tempVar $ updateTemp Map.delete
              when report $ putTMVar sender Nothing
          , recvMsgAwait = \status _ -> do
              report' <- liftIO case status of
                Accepted -> do
                  when report $ atomically do
                    putTMVar sender Nothing
                    modifyTVar tempVar $ updateTemp $ Map.update (Just . toSubmitted)
                  pure False
                _ -> pure report
              delay <- liftIO $ newDelay 1_000_000
              liftIO $ atomically $ waitDelay delay
              pure $ SendMsgPoll $ clientCmd report'
          }
      runSomeConnectorTraced connector $ RunTxClient client

    genericSubmit
      :: SomeTVarWithMapUpdate
      -> r
      -> Tx BabbageEra
      -> m (Maybe SubmitError)
    genericSubmit tVarWithUpdate currentParent tx = do
      liftIO do
        sender <- atomically do
          sender <- newEmptyTMVar
          writeTQueue submitQueue (tVarWithUpdate, tx, sender, currentParent)
          pure sender
        atomically $ takeTMVar sender

    runTxClient = withRunInIO \runInIO -> do
      (tVarWithUpdate, tx, sender, currentParent) <- atomically $ readTQueue submitQueue
      concurrently_
        (try @SomeException $ runInIO $ localBackend (setAncestorEventBackend currentParent) $ runSubmitGeneric tVarWithUpdate tx sender)
        (runInIO runTxClient)

  pure (runTxClient, TxClient
    { createContract = \stakeCredential version addresses roles metadata minUTxODeposit contract -> do
        response <- runSomeConnectorTraced connector
          $ RunTxClient
          $ liftCommand
          $ Create stakeCredential version addresses roles metadata minUTxODeposit
          $ Left contract
        liftIO $ for_ response \creation@ContractCreated{contractId} -> atomically
          $ modifyTVar tempContracts
          $ Map.insert contractId
          $ TempTx version Unsigned creation
        pure response
    , applyInputs = \version addresses contractId metadata invalidBefore invalidHereafter inputs -> do
        response <- runSomeConnectorTraced connector
          $ RunTxClient
          $ liftCommand
          $ ApplyInputs version addresses contractId metadata invalidBefore invalidHereafter inputs
        liftIO $ for_ response \application@InputsApplied{txBody} -> do
          let txId = fromCardanoTxId $ getTxId txBody
          let tempTx = TempTx version Unsigned application
          atomically
            $ modifyTVar tempTransactions
            $ Map.alter (Just . maybe (Map.singleton txId tempTx) (Map.insert txId tempTx)) contractId
        pure response
    , withdraw = \version addresses contractId role -> do
        response <- runSomeConnectorTraced connector
          $ RunTxClient
          $ liftCommand
          $ Withdraw version addresses contractId role
        liftIO $ for_ response \txBody-> atomically
          $ modifyTVar tempWithdrawals
          $ Map.insert (fromCardanoTxId $ getTxId txBody)
          $ TempTx version Unsigned
          $ Withdrawn txBody
        pure response
    , submitContract = \contractId -> genericSubmit $ SomeTVarWithMapUpdate tempContracts ($ contractId)
    , submitTransaction = \contractId txId -> genericSubmit $ SomeTVarWithMapUpdate tempTransactions \update -> Map.update (Just . update txId) contractId
    , submitWithdrawal = \txId -> genericSubmit $ SomeTVarWithMapUpdate tempWithdrawals ($ txId)
    , lookupTempContract = \contractId -> Map.lookup contractId <$> readTVar tempContracts
    , getTempContracts = fmap snd . Map.toAscList <$> readTVar tempContracts
    , lookupTempTransaction = \contractId txId -> (Map.lookup txId <=< Map.lookup contractId) <$> readTVar tempTransactions
    , getTempTransactions = \contractId -> fmap snd . foldMap Map.toList . Map.lookup contractId <$> readTVar tempTransactions
    , lookupTempWithdrawal = \txId -> Map.lookup txId <$> readTVar tempWithdrawals
    , getTempWithdrawals = fmap snd . Map.toAscList <$> readTVar tempWithdrawals
    })

toSubmitted :: TempTx tx -> TempTx tx
toSubmitted (TempTx v _ tx) = TempTx v Submitted tx

toUnsigned :: TempTx tx -> TempTx tx
toUnsigned (TempTx v _ tx) = TempTx v Unsigned tx
