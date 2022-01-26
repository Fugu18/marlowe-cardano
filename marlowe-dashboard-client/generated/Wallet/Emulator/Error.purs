-- File auto generated by purescript-bridge! --
module Wallet.Emulator.Error where

import Prelude

import Control.Lazy (defer)
import Data.Argonaut.Core (jsonNull)
import Data.Argonaut.Decode (class DecodeJson)
import Data.Argonaut.Decode.Aeson ((</$\>), (</*\>), (</\>))
import Data.Argonaut.Decode.Aeson as D
import Data.Argonaut.Encode (class EncodeJson, encodeJson)
import Data.Argonaut.Encode.Aeson ((>$<), (>/\<))
import Data.Argonaut.Encode.Aeson as E
import Data.Generic.Rep (class Generic)
import Data.Lens (Iso', Lens', Prism', iso, prism')
import Data.Lens.Iso.Newtype (_Newtype)
import Data.Lens.Record (prop)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Newtype (unwrap)
import Data.Show.Generic (genericShow)
import Data.Tuple.Nested ((/\))
import Ledger.Address (PaymentPubKeyHash)
import Ledger.Constraints.OffChain (MkTxError)
import Ledger.Index (ValidationError)
import Ledger.Tx.CardanoAPI (ToCardanoError)
import Plutus.V1.Ledger.Ada (Ada)
import Plutus.V1.Ledger.Value (Value)
import Type.Proxy (Proxy(Proxy))

data WalletAPIError
  = InsufficientFunds String
  | ChangeHasLessThanNAda Value Ada
  | PaymentPrivateKeyNotFound PaymentPubKeyHash
  | ValidationError ValidationError
  | ToCardanoError ToCardanoError
  | PaymentMkTxError MkTxError
  | RemoteClientFunctionNotYetSupported String
  | OtherError String

derive instance eqWalletAPIError :: Eq WalletAPIError

instance showWalletAPIError :: Show WalletAPIError where
  show a = genericShow a

instance encodeJsonWalletAPIError :: EncodeJson WalletAPIError where
  encodeJson = defer \_ -> case _ of
    InsufficientFunds a -> E.encodeTagged "InsufficientFunds" a E.value
    ChangeHasLessThanNAda a b -> E.encodeTagged "ChangeHasLessThanNAda" (a /\ b)
      (E.tuple (E.value >/\< E.value))
    PaymentPrivateKeyNotFound a -> E.encodeTagged "PaymentPrivateKeyNotFound" a
      E.value
    ValidationError a -> E.encodeTagged "ValidationError" a E.value
    ToCardanoError a -> E.encodeTagged "ToCardanoError" a E.value
    PaymentMkTxError a -> E.encodeTagged "PaymentMkTxError" a E.value
    RemoteClientFunctionNotYetSupported a -> E.encodeTagged
      "RemoteClientFunctionNotYetSupported"
      a
      E.value
    OtherError a -> E.encodeTagged "OtherError" a E.value

instance decodeJsonWalletAPIError :: DecodeJson WalletAPIError where
  decodeJson = defer \_ -> D.decode
    $ D.sumType "WalletAPIError"
    $ Map.fromFoldable
        [ "InsufficientFunds" /\ D.content (InsufficientFunds <$> D.value)
        , "ChangeHasLessThanNAda" /\ D.content
            (D.tuple $ ChangeHasLessThanNAda </$\> D.value </*\> D.value)
        , "PaymentPrivateKeyNotFound" /\ D.content
            (PaymentPrivateKeyNotFound <$> D.value)
        , "ValidationError" /\ D.content (ValidationError <$> D.value)
        , "ToCardanoError" /\ D.content (ToCardanoError <$> D.value)
        , "PaymentMkTxError" /\ D.content (PaymentMkTxError <$> D.value)
        , "RemoteClientFunctionNotYetSupported" /\ D.content
            (RemoteClientFunctionNotYetSupported <$> D.value)
        , "OtherError" /\ D.content (OtherError <$> D.value)
        ]

derive instance genericWalletAPIError :: Generic WalletAPIError _

--------------------------------------------------------------------------------

_InsufficientFunds :: Prism' WalletAPIError String
_InsufficientFunds = prism' InsufficientFunds case _ of
  (InsufficientFunds a) -> Just a
  _ -> Nothing

_ChangeHasLessThanNAda :: Prism' WalletAPIError { a :: Value, b :: Ada }
_ChangeHasLessThanNAda = prism' (\{ a, b } -> (ChangeHasLessThanNAda a b))
  case _ of
    (ChangeHasLessThanNAda a b) -> Just { a, b }
    _ -> Nothing

_PaymentPrivateKeyNotFound :: Prism' WalletAPIError PaymentPubKeyHash
_PaymentPrivateKeyNotFound = prism' PaymentPrivateKeyNotFound case _ of
  (PaymentPrivateKeyNotFound a) -> Just a
  _ -> Nothing

_ValidationError :: Prism' WalletAPIError ValidationError
_ValidationError = prism' ValidationError case _ of
  (ValidationError a) -> Just a
  _ -> Nothing

_ToCardanoError :: Prism' WalletAPIError ToCardanoError
_ToCardanoError = prism' ToCardanoError case _ of
  (ToCardanoError a) -> Just a
  _ -> Nothing

_PaymentMkTxError :: Prism' WalletAPIError MkTxError
_PaymentMkTxError = prism' PaymentMkTxError case _ of
  (PaymentMkTxError a) -> Just a
  _ -> Nothing

_RemoteClientFunctionNotYetSupported :: Prism' WalletAPIError String
_RemoteClientFunctionNotYetSupported = prism'
  RemoteClientFunctionNotYetSupported
  case _ of
    (RemoteClientFunctionNotYetSupported a) -> Just a
    _ -> Nothing

_OtherError :: Prism' WalletAPIError String
_OtherError = prism' OtherError case _ of
  (OtherError a) -> Just a
  _ -> Nothing