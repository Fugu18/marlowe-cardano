{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}

module Network.Protocol.Connection
  where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (STM, TQueue, atomically, newTQueue, readTQueue, writeTQueue)
import Control.Exception (SomeException)
import Control.Monad.Base (MonadBase, liftBase)
import Control.Monad.Cleanup (MonadCleanup)
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.Base16 (encodeBase16)
import qualified Data.Text.Lazy as T
import Data.Void (Void)
import Network.Channel
  (Channel(..), ChannelSelector, STMChannel(..), channelPair, getChannelSelectorConfig, hoistChannel, logChannel)
import Network.Protocol.Codec (BinaryMessage)
import Network.Protocol.Peer (PeerSelector, getPeerSelectorConfig, hoistPeer, logPeer)
import Network.TypedProtocol
import Observe.Event (EventBackend, causedEventBackend, failEvent, finalize, newEvent, withEvent)
import Observe.Event.Backend (narrowEventBackend)
import Observe.Event.Component (GetSelectorConfig, SelectorConfig(..), absurdFieldConfig, prependKey)
import Observe.Event.Network.Protocol (MessageToJSON)

type ToPeer peer protocol pr st m = forall a. peer m a -> Peer protocol pr st m a

newtype Connector ps pr peer m = Connector
  { openConnection :: m (Connection ps pr peer m)
  }

ihoistConnector
  :: (Functor m, Functor n)
  => (forall p q a. Functor p => (forall x. p x -> q x) -> peer p a -> peer q a)
  -> (forall x. m x -> n x)
  -> (forall x. n x -> m x)
  -> Connector ps pr peer m
  -> Connector ps pr peer n
ihoistConnector hoistPeer' f f' Connector{..} = Connector $ f $ ihoistConnection hoistPeer' f f' <$> openConnection

type ClientConnector ps = Connector ps 'AsClient
type ServerConnector ps = Connector ps 'AsServer

data SomeConnector pr peer m =
  forall ps. BinaryMessage ps => SomeConnector (Connector ps pr peer m)

type SomeClientConnector = SomeConnector 'AsClient
type SomeServerConnector = SomeConnector 'AsServer

newtype ConnectionSource ps server m = ConnectionSource
  { acceptConnector :: STM (Connector ps 'AsServer server m)
  }

mergeConnectionSource :: ConnectionSource ps server m -> ConnectionSource ps server m -> ConnectionSource ps server m
mergeConnectionSource (ConnectionSource source1) (ConnectionSource source2) = ConnectionSource $ source1 <|> source2

data SomeConnectionSource server m =
  forall ps. BinaryMessage ps => SomeConnectionSource (ConnectionSource ps server m)

data ConnectorSelector ps f where
  Connect :: ConnectorSelector ps Void
  ConnectionSelector :: ConnectionSelector ps f -> ConnectorSelector ps f

getConnectorSelectorConfig
  :: MessageToJSON ps
  => Bool -- ^ Enable channel messages
  -> Bool -- ^ Enable peer messages
  -> GetSelectorConfig (ConnectorSelector ps)
getConnectorSelectorConfig channelEnabled peerEnabled = \case
  Connect -> SelectorConfig "connect" True absurdFieldConfig
  ConnectionSelector sel -> prependKey "connection" $ getConnectionSelectorConfig channelEnabled peerEnabled sel

logConnector
  :: (MonadBaseControl IO m, MonadCleanup m)
  => EventBackend m r (ConnectorSelector ps)
  -> Connector ps pr peer m
  -> Connector ps pr peer m
logConnector eventBackend Connector{..} = Connector
  { openConnection = withEvent eventBackend Connect \ev ->
      logConnection (causedEventBackend ConnectionSelector ev) <$> openConnection
  }

logConnectionSource
  :: (MonadBaseControl IO m, MonadCleanup m)
  => EventBackend m r (ConnectorSelector ps)
  -> ConnectionSource ps server m
  -> ConnectionSource ps server m
logConnectionSource eventBackend ConnectionSource{..} = ConnectionSource
  { acceptConnector = logConnector eventBackend <$> acceptConnector
  }

data Connection ps pr peer m = forall (st :: ps). Connection
  { closeConnection :: Maybe SomeException -> m ()
  , channel :: Channel m ByteString
  , toPeer :: forall a. peer m a -> Peer ps pr st m a
  }

ihoistConnection
  :: (Functor m, Functor n)
  => (forall p q a. Functor p => (forall x. p x -> q x) -> peer p a -> peer q a)
  -> (forall x. m x -> n x)
  -> (forall x. n x -> m x)
  -> Connection ps pr peer m
  -> Connection ps pr peer n
ihoistConnection hoistPeer' f f' Connection{..} = Connection
  { closeConnection = f . closeConnection
  , channel = hoistChannel f channel
  , toPeer = hoistPeer f . toPeer . hoistPeer' f'
  }

data ConnectionSelector ps f where
  ChannelSelector :: ChannelSelector ByteString f -> ConnectionSelector ps f
  PeerSelector :: PeerSelector ps f -> ConnectionSelector ps f
  Close :: ConnectionSelector ps Void

getConnectionSelectorConfig
  :: MessageToJSON ps
  => Bool
  -> Bool
  -> GetSelectorConfig (ConnectionSelector ps)
getConnectionSelectorConfig channelEnabled peerEnabled = \case
  ChannelSelector sel -> prependKey "channel" $ getChannelSelectorConfig (T.toStrict . encodeBase16) channelEnabled sel
  PeerSelector sel -> prependKey "peer" $ getPeerSelectorConfig peerEnabled sel
  Close -> SelectorConfig "close" True absurdFieldConfig

logConnection
  :: (MonadBaseControl IO m, MonadCleanup m)
  => EventBackend m r (ConnectionSelector ps)
  -> Connection ps pr peer m
  -> Connection ps pr peer m
logConnection eventBackend Connection{..} = Connection
  { channel = logChannel (narrowEventBackend ChannelSelector eventBackend) channel
  , toPeer = logPeer (narrowEventBackend PeerSelector eventBackend) . toPeer
  , closeConnection = \mError -> do
      ev <- newEvent eventBackend Close
      case mError of
        Nothing -> finalize ev
        Just ex -> failEvent ev ex
      closeConnection mError
  }

acceptSomeConnector :: MonadBaseControl IO m => SomeConnectionSource server m -> m (SomeServerConnector server m)
acceptSomeConnector (SomeConnectionSource ConnectionSource{..}) = liftBase $ SomeConnector <$> atomically acceptConnector

stmConnectionSource
  :: MonadBase IO m
  => TQueue (STMChannel ByteString)
  -> ToPeer server ps 'AsServer st m
  -> ConnectionSource ps server m
stmConnectionSource queue toPeer = ConnectionSource do
  channel <- readTQueue queue
  pure $ stmServerConnector channel toPeer

stmServerConnector
  :: MonadBase IO m
  => STMChannel ByteString
  -> ToPeer client ps 'AsServer st m
  -> ServerConnector ps client m
stmServerConnector (STMChannel channel closeChannel) toPeer = Connector $ pure Connection
  { closeConnection = const $ liftBase $ atomically closeChannel
  , channel = hoistChannel (liftBase . atomically) channel
  , ..
  }

stmClientConnector
  :: MonadBase IO m
  => TQueue (STMChannel ByteString)
  -> ToPeer client ps 'AsClient st m
  -> ClientConnector ps client m
stmClientConnector queue toPeer = Connector do
  STMChannel channel closeChannel <- liftBase $ atomically do
    (clientChannel, serverChannel) <- channelPair
    writeTQueue queue serverChannel
    pure clientChannel
  pure Connection
    { closeConnection = \_ -> liftBase $ atomically closeChannel
    , channel = hoistChannel (liftBase . atomically) channel
    , ..
    }

data ClientServerPair ps server client m = ClientServerPair
  { connectionSource :: ConnectionSource ps server m
  , clientConnector :: ClientConnector ps client m
  }

data ClientServerPairSelector ps f where
  ClientEvent :: ConnectorSelector ps f -> ClientServerPairSelector ps f
  ServerEvent :: ConnectorSelector ps f -> ClientServerPairSelector ps f

getClientServerPairSelectorConfig
  :: MessageToJSON ps
  => Bool
  -> Bool
  -> GetSelectorConfig (ClientServerPairSelector ps)
getClientServerPairSelectorConfig channelEnabled peerEnabled = \case
  ClientEvent sel -> prependKey "client" $ getConnectorSelectorConfig channelEnabled peerEnabled sel
  ServerEvent sel -> prependKey "server" $ getConnectorSelectorConfig channelEnabled peerEnabled sel

logClientServerPair
  :: forall ps server client m r
   . (MonadBaseControl IO m, MonadCleanup m)
  => EventBackend m r (ClientServerPairSelector ps)
  -> ClientServerPair ps server client m
  -> ClientServerPair ps server client m
logClientServerPair eventBackend ClientServerPair{..} = ClientServerPair
  { connectionSource = logConnectionSource (narrowEventBackend ServerEvent eventBackend) connectionSource
  , clientConnector = logConnector (narrowEventBackend ClientEvent eventBackend) clientConnector
  }

clientServerPair
  :: forall ps server client m st
   . MonadBaseControl IO m
  => ToPeer server ps 'AsServer st m
  -> ToPeer client ps 'AsClient st m
  -> STM (ClientServerPair ps server client m)
clientServerPair serverToPeer clientToPeer = do
  serverChannelQueue <- newTQueue
  let
  pure ClientServerPair
    { connectionSource = stmConnectionSource serverChannelQueue serverToPeer
    , clientConnector = stmClientConnector serverChannelQueue clientToPeer
    }