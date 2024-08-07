{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Language.Marlowe.Core.V1.Next.Applicables (
  ApplicableInputs (..),
  emptyApplicables,
  filterByParties,
  mkApplicables,
  mkApplicablesWhen,
) where

import Control.Applicative (Alternative ((<|>)))
import Data.Aeson (FromJSON (parseJSON), KeyValue ((.=)), ToJSON (toJSON), Value (Object), object, (.:))
import Data.Aeson.Types ()
import Data.Coerce (coerce)
import Data.Monoid as Haskell (First (First))

import Data.List (nubBy)
import Deriving.Aeson (Generic)
import Language.Marlowe.Core.V1.Semantics (evalObservation, evalValue)
import Language.Marlowe.Core.V1.Semantics.Types (
  Action (Choice, Deposit, Notify),
  Case (..),
  ChoiceId (ChoiceId),
  Contract (Close, When),
  Environment,
  Party,
  State,
 )
import Language.Marlowe.Pretty (Pretty (..))

import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (maybeToList)
import Language.Marlowe.Core.V1.Next.Applicables.CanChoose (CanChoose (CanChoose, choiceId), difference)
import Language.Marlowe.Core.V1.Next.Applicables.CanDeposit (CanDeposit (..))
import Language.Marlowe.Core.V1.Next.Applicables.CanNotify (CanNotify (..))
import Language.Marlowe.Core.V1.Next.Indexed (CaseIndex, Indexed (..), caseIndexed, sameIndexedValue)
import Language.Marlowe.Core.V1.Next.IsMerkleizedContinuation (IsMerkleizedContinuation (IsMerkleizedContinuation))
import Prelude

data ApplicableInputs = ApplicableInputs
  { notifyMaybe :: Maybe (Indexed CanNotify)
  , deposits :: [Indexed CanDeposit]
  , choices :: [Indexed CanChoose]
  }
  deriving stock (Show, Eq, Ord, Generic)
  deriving anyclass (Pretty)

filterByParties :: Maybe (NonEmpty Party) -> ApplicableInputs -> ApplicableInputs
filterByParties Nothing a = a
filterByParties (Just parties) ApplicableInputs{..} =
  ApplicableInputs
    { notifyMaybe = notifyMaybe
    , deposits = filter (\(Indexed _ (CanDeposit party _ _ _ _)) -> elem party parties) deposits
    , choices = filter (\(Indexed _ CanChoose{choiceId = (ChoiceId _ party)}) -> elem party parties) choices
    }

emptyApplicables :: ApplicableInputs
emptyApplicables = ApplicableInputs Nothing mempty mempty

mkApplicables :: Environment -> State -> Contract -> ApplicableInputs
mkApplicables _ _ Close = emptyApplicables
mkApplicables environment state (When xs _ _) = mkApplicablesWhen environment state xs
mkApplicables _ _ _ = emptyApplicables

mkApplicablesWhen :: Environment -> State -> [Case Contract] -> ApplicableInputs
mkApplicablesWhen environment state =
  foldl mergeApplicables emptyApplicables
    . (uncurry (toApplicable environment state) <$>)
    . caseIndexed

data ApplicableInput
  = IndexedCanNotify (Indexed CanNotify)
  | IndexedCanDeposit (Indexed CanDeposit)
  | IndexedCanChoose (Indexed CanChoose)

mergeApplicables
  :: ApplicableInputs
  -> Maybe ApplicableInput
  -> ApplicableInputs
mergeApplicables b (Just (IndexedCanNotify a)) =
  ApplicableInputs
    (coerce $ (First . notifyMaybe $ b) <> (First . Just $ a)) -- First Notity evaluated to True is applicable
    (deposits b)
    (choices b)
mergeApplicables b (Just (IndexedCanDeposit a)) =
  ApplicableInputs
    (notifyMaybe b)
    (nubBy sameIndexedValue $ deposits b ++ [a]) -- Following Duplicated Deposits are not applicable.
    (choices b)
mergeApplicables b (Just (IndexedCanChoose a)) =
  ApplicableInputs
    (notifyMaybe b)
    (deposits b)
    (choices b ++ (maybeToList $ a `difference` choices b)) -- Choices with empty Bounds and following overlapping Choices with same choice Id are not applicable.
mergeApplicables b _ = b

toApplicable
  :: Environment
  -> State
  -> CaseIndex
  -> Case Contract
  -> Maybe ApplicableInput
toApplicable environment state caseIndex =
  \case
    (merkleizedContinuation, Deposit accountId party token value) ->
      Just . IndexedCanDeposit . Indexed caseIndex . CanDeposit accountId party token (evalValue environment state value) $
        merkleizedContinuation
    (merkleizedContinuation, Choice choiceId bounds) ->
      Just . IndexedCanChoose . Indexed caseIndex . CanChoose choiceId bounds $ merkleizedContinuation
    (merkleizedContinuation, Notify observation)
      | evalObservation environment state observation ->
          Just . IndexedCanNotify . Indexed caseIndex . CanNotify $ merkleizedContinuation
    (_, Notify _) -> Nothing
    . \case
      (Case action _) -> (IsMerkleizedContinuation False, action)
      (MerkleizedCase action _) -> (IsMerkleizedContinuation True, action)

instance FromJSON ApplicableInputs where
  parseJSON (Object v) =
    ApplicableInputs
      <$> v .: "notify"
      <*> v .: "deposits"
      <*> v .: "choices"
      <|> ApplicableInputs Nothing
        <$> (v .: "deposits")
        <*> v .: "choices"
  parseJSON _ = fail "Applicables must be an object with 2 compulsory fields (deposits,choices) and 1 optional (notify)"

instance ToJSON ApplicableInputs where
  toJSON ApplicableInputs{notifyMaybe = Nothing, ..} =
    object
      [ "deposits" .= deposits
      , "choices" .= choices
      ]
  toJSON ApplicableInputs{notifyMaybe = Just notify, ..} =
    object
      [ "notify" .= notify
      , "deposits" .= deposits
      , "choices" .= choices
      ]
