{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Spec.Actus.Examples
    (tests)
where

import Actus.Domain.BusinessEvents
import Actus.Domain.ContractTerms
import Actus.Domain.Ops
import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy as B (readFile)
import Data.Maybe (fromJust)
import Data.Time.LocalTime
import Data.Validation (Validation (..))
import Generator
import Language.Marlowe
import qualified Ledger.Value as Val
import Spec.Actus.Haskell
import Spec.Actus.Helper
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "Marlowe represenation of sample ACTUS contracts"
  [ testCase "PAM examples" ex_pam1
  , testCase "LAM examples" ex_lam1
  , testCase "NAM examples" ex_nam1
  , testCase "ANN examples" ex_ann1
  , testCase "OPTNS examples" ex_optns1
  , testCase "COM examples" ex_com1
  ]

-- |ex_pam1 defines a contract of type PAM
--
-- principal: 10000
-- interest rate: 2% p.a.
-- annual interest payments
-- term: 10 years
--
-- cashflows:
-- 0 : -10000
-- 1 :    200
-- 2 :    200
-- 3 :    200
-- 4 :    200
-- 5 :    200
-- 6 :    200
-- 7 :    200
-- 8 :    200
-- 9 :    200
-- 10:  10200
ex_pam1 :: IO ()
ex_pam1 =
  contractFromFile "test/Spec/Marlowe/ACTUS/ex_pam1.json"
    >>= either
      ( \err -> assertFailure ("Error parsing file: " ++ err))
      ( \ct -> case genContract defaultRiskFactors (toMarlowe ct) of
          Failure _ -> assertFailure "Terms validation should not fail"
          Success contract ->
            let principal = NormalInput $ IDeposit (Role "counterparty") "counterparty" ada 10000
                ip = NormalInput $ IDeposit (Role "party") "party" ada 200
                redemption = NormalInput $ IDeposit (Role "party") "party" ada 10000

                out =
                  computeTransaction
                    ( TransactionInput
                        (0, 0)
                        [ principal,
                          ip,
                          ip,
                          ip,
                          ip,
                          ip,
                          ip,
                          ip,
                          ip,
                          ip,
                          ip,
                          redemption
                        ]
                    )
                    (emptyState 0)
                    contract
             in case out of
                  Error err -> assertFailure $ "Transactions are not expected to fail: " ++ show err
                  TransactionOutput txWarn txPay _ con -> do
                    assertBool "Contract is in Close" $ con == Close
                    assertBool "No warnings" $ null txWarn

                    assertBool "total payments to party" (totalPayments (Party "party") txPay == 10000)
                    assertBool "total payments to counterparty" (totalPayments (Party "counterparty") txPay == 12000)
      )

-- |ex_lam1 defines a contract of type LAM
--
-- principal: 10000
-- interest rate: 2% p.a.
-- annual interest payments
-- term: 10 years
--
-- cashflows:
-- 0 : -10000
-- 1 :   1200
-- 2 :   1180
-- 3 :   1160
-- 4 :   1140
-- 5 :   1120
-- 6 :   1100
-- 7 :   1080
-- 8 :   1060
-- 9 :   1040
-- 10:   1020
ex_lam1 :: IO ()
ex_lam1 =
  contractFromFile "test/Spec/Marlowe/ACTUS/ex_lam1.json"
    >>= either
      ( \err -> assertFailure ("Error parsing file: " ++ err))
      ( \ct -> case genContract defaultRiskFactors (toMarlowe ct) of
          Failure _ -> assertFailure "Terms validation should not fail"
          Success contract ->
            let principal = NormalInput $ IDeposit (Role "counterparty") "counterparty" ada 10000
                pr i = NormalInput $ IDeposit (Role "party") "party" ada i
                ip i = NormalInput $ IDeposit (Role "party") "party" ada i
                out =
                  computeTransaction
                    ( TransactionInput
                        (0, 0)
                        [ principal,
                          pr 1000, ip 200,
                          pr 1000, ip 180,
                          pr 1000, ip 160,
                          pr 1000, ip 140,
                          pr 1000, ip 120,
                          pr 1000, ip 100,
                          pr 1000, ip 80,
                          pr 1000, ip 60,
                          pr 1000, ip 40,
                                   ip 20,
                          pr 1000
                        ]
                    )
                    (emptyState 0)
                    contract
             in case out of
                  Error _ -> assertFailure "Transactions are not expected to fail"
                  TransactionOutput txWarn txPay _ con -> do
                    assertBool "Contract is in Close" $ con == Close
                    assertBool "No warnings" $ null txWarn

                    assertBool "total payments to party" (totalPayments (Party "party") txPay == 10000)
                    let tc = totalPayments (Party "counterparty") txPay
                    assertBool ("total payments to counterparty: " ++ show tc) (tc == 11100)
      )

-- |ex_nam1 defines a contract of type NAM
--
-- principal: 10000
-- interest rate: 2% p.a.
-- annual interest payments
-- term: 10 years
--
-- cashflows:
-- 0 : -10000
-- 1 :   1000
-- 2 :   1000
-- 3 :   1000
-- 4 :   1000
-- 5 :   1000
-- 6 :   1000
-- 7 :   1000
-- 8 :   1000
-- 9 :   1000
-- 10:   2240
ex_nam1 :: IO ()
ex_nam1 =
  contractFromFile "test/Spec/Marlowe/ACTUS/ex_nam1.json"
    >>= either
      ( \err -> assertFailure ("Error parsing file: " ++ err))
      ( \ct -> case genContract defaultRiskFactors (toMarlowe ct) of
        Failure _ -> assertFailure "Terms validation should not fail"
        Success contract ->
          let principal = NormalInput $ IDeposit (Role "counterparty") "counterparty" ada 10000
              pr i = NormalInput $ IDeposit (Role "party") "party" ada i
              ip i = NormalInput $ IDeposit (Role "party") "party" ada i
              out =
                computeTransaction
                  ( TransactionInput
                      (0, 0)
                      [ principal,
                        pr 800, ip 200,
                        pr 816, ip 184,
                        pr 832, ip 168,
                        pr 849, ip 151,
                        pr 866, ip 134,
                        pr 883, ip 117,
                        pr 901, ip 99,
                        pr 919, ip 81,
                        pr 937, ip 63,
                                ip 44,
                        pr 2196
                      ]
                  )
                  (emptyState 0)
                  contract
           in case out of
                Error _ -> assertFailure "Transactions are not expected to fail"
                TransactionOutput txWarn txPay _ con -> do
                  assertBool "Contract is in Close" $ con == Close
                  assertBool "No warnings" $ null txWarn

                  assertBool "total payments to party" (totalPayments (Party "party") txPay == 10000)
                  let tc = totalPayments (Party "counterparty") txPay
                  assertBool ("total payments to counterparty: " ++ show tc) (tc == 11240)
      )

-- |ex_ann1 defines a contract of type ANN
--
-- principal: 10000
-- interest rate: 2% p.a.
-- annual interest payments
-- term: 10 years
--
-- cashflows:
-- 0 : -10000
-- 1 :   1000
-- 2 :   1000
-- 3 :   1000
-- 4 :   1000
-- 5 :   1000
-- 6 :   1000
-- 7 :   1000
-- 8 :   1000
-- 9 :   1000
-- 10:   2240
ex_ann1 :: IO ()
ex_ann1 =
  contractFromFile "test/Spec/Marlowe/ACTUS/ex_ann1.json"
    >>= either
      ( \err -> assertFailure ("Error parsing file: " ++ err))
      ( \ct -> case genContract defaultRiskFactors (toMarlowe ct) of
        Failure _ -> assertFailure "Terms validation should not fail"
        Success contract ->
          let principal = NormalInput $ IDeposit (Role "counterparty") "counterparty" ada 10000
              pr i = NormalInput $ IDeposit (Role "party") "party" ada i
              ip i = NormalInput $ IDeposit (Role "party") "party" ada i
              out =
                computeTransaction
                  ( TransactionInput
                      (0, 0)
                      [ principal,
                        pr 800, ip 200,
                        pr 816, ip 184,
                        pr 832, ip 168,
                        pr 849, ip 151,
                        pr 866, ip 134,
                        pr 883, ip 117,
                        pr 901, ip 99,
                        pr 919, ip 81,
                        pr 937, ip 63,
                                ip 44,
                        pr 2196
                      ]
                  )
                  (emptyState 0)
                  contract
           in case out of
                Error _ -> assertFailure "Transactions are not expected to fail"
                TransactionOutput txWarn txPay _ con -> do
                  assertBool "Contract is in Close" $ con == Close
                  assertBool "No warnings" $ null txWarn

                  assertBool "total payments to party" (totalPayments (Party "party") txPay == 10000)
                  let tc = totalPayments (Party "counterparty") txPay
                  assertBool ("total payments to counterparty: " ++ show tc) (tc == 11240)
      )

-- |ex_optns1 defines a contract of type OPTNS
ex_optns1 :: IO ()
ex_optns1 =
  contractFromFile "test/Spec/Marlowe/ACTUS/ex_optns1.json"
    >>= either msg run
  where
    msg err = putStr err
    run ct = case genContract rf (toMarlowe ct) of
      Failure _ -> assertFailure "Terms validation should not fail"
      Success contract ->
          let principal = NormalInput . IDeposit (Role "counterparty") "counterparty" ada
              ex = NormalInput . IDeposit (Role "party") "party" ada
              out =
                computeTransaction
                  ( TransactionInput
                      (0, 0)
                      [ principal 10,
                        ex 40
                      ]
                  )
                  (emptyState 0)
                  contract
           in case out of
                Error _ -> assertFailure "Transactions are not expected to fail"
                TransactionOutput txWarn txPay _ con -> do
                  assertBool "Contract is in Close" $ con == Close
                  assertBool "No warnings" $ null txWarn

                  assertBool "total payments to party" (totalPayments (Party "party") txPay == 10)
                  let tc = totalPayments (Party "counterparty") txPay
                  assertBool ("total payments to counterparty: " ++ show tc) (tc == 40)

      where
        rf :: EventType -> LocalTime -> RiskFactorsPoly (Value Observation)
        rf XD d
          | d == (fromJust $ maturityDate ct) =
            RiskFactorsPoly
              { o_rf_CURS = _one,
                o_rf_RRMO = _one,
                o_rf_SCMO = _one,
                pp_payoff = _zero,
                xd_payoff = constant 120,
                dv_payoff = _zero
              }
        rf _ _ =
          RiskFactorsPoly
            { o_rf_CURS = _one,
              o_rf_RRMO = _one,
              o_rf_SCMO = _one,
              pp_payoff = _zero,
              xd_payoff = _zero,
              dv_payoff = _zero
            }


-- |ex_com1 defines a contract of type COM
ex_com1 :: IO ()
ex_com1 =
  contractFromFile "test/Spec/Marlowe/ACTUS/ex_com1.json"
    >>= either msg run
  where
    msg err = putStr err
    run ct = case genContract defaultRiskFactors (toMarlowe ct) of
      Failure _ -> assertFailure "Terms validation should not fail"
      Success contract ->
          let principal = NormalInput . IDeposit (Role "party") "party" ada
              out =
                computeTransaction
                  ( TransactionInput
                      (0, 0)
                      [ principal 1400
                      ]
                  )
                  (emptyState 0)
                  contract
           in case out of
                Error _ -> assertFailure "Transactions are not expected to fail"
                TransactionOutput txWarn txPay _ con -> do
                  assertBool "Contract is in Close" $ con == Close
                  assertBool "No warnings" $ null txWarn

                  assertBool "total payments to party" (totalPayments (Party "party") txPay == 0)
                  let tc = totalPayments (Party "counterparty") txPay
                  assertBool ("total payments to counterparty: " ++ show tc) (tc == 1400)

contractFromFile :: FilePath -> IO (Either String ContractTerms)
contractFromFile f = eitherDecode <$> B.readFile f

defaultRiskFactors :: ActusOps a => EventType -> LocalTime -> RiskFactorsPoly a
defaultRiskFactors _ _ =
  RiskFactorsPoly
    { o_rf_CURS = _one,
      o_rf_RRMO = _one,
      o_rf_SCMO = _one,
      pp_payoff = _zero,
      xd_payoff = _zero,
      dv_payoff = _zero
    }

-- |totalPayments calculates the sum of the payments provided as argument
totalPayments :: Payee -> [Payment] -> Integer
totalPayments payee = sum . map m . filter f
  where
    m (Payment _ _ mon) = Val.valueOf mon "" ""
    f (Payment _ pay _) = pay == payee
