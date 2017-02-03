{-# LANGUAGE Trustworthy, PatternGuards, MultiWayIf #-}
module Cryptol.TypeCheck.Solver.Numeric
  ( cryIsEqual, cryIsNotEqual, cryIsGeq
  ) where

import           Control.Monad (msum,guard,mzero)
import           Data.Function (on)
import           Data.List (sortBy)
import           Data.Maybe (catMaybes,listToMaybe)
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set

import Cryptol.TypeCheck.PP
import Cryptol.TypeCheck.Type
import Cryptol.TypeCheck.Solver.Types
import Cryptol.TypeCheck.Solver.InfNat
import Cryptol.TypeCheck.Solver.Numeric.Interval

import Debug.Trace

cryIsEqual :: Map TVar Interval -> Type -> Type -> Solved
cryIsEqual fin t1 t2 =
  solveOpts
    [ pBin PEqual (==) fin t1 t2
    , tIsNat' t1 `matchThen` \n -> tryEqK n t2
    , tIsNat' t2 `matchThen` \n -> tryEqK n t1
    , tIsVar t1 `matchThen` \tv -> tryEqInf tv t2
    , tIsVar t2 `matchThen` \tv -> tryEqInf tv t1
    , guarded (t1 == t2) $ SolvedIf []

    -- x = min (K + x) y --> x = y
    ]

{-
  case 
    Unsolved
      | Just x <- tIsVar t1, isFreeTV x -> Unsolved

      | Just n <- tIsNat' t1 -> tryEqK n t2
      | Just n <- tIsNat' t2 -> tryEqK n t1

      | Just (x,t) <- tryRewrteEqAsSubst fin t1 t2 ->
        let new = show (pp x) ++ " == " ++ show (pp t)
        in
          trace ("Rewrote: " ++ sh ++ " -> " ++ new)
         $ SolvedIf [ TCon (PC PEqual) [TVar x,t] ]

    Unsolved -> trace ("Failed to rewrite eq: " ++ sh) Unsolved

    x -> x
  where
  sh = show (pp t1) ++ " == " ++ show (pp t2)
-}



cryIsNotEqual :: Map TVar Interval -> Type -> Type -> Solved
cryIsNotEqual = pBin PNeq (/=)

cryIsGeq :: Map TVar Interval -> Type -> Type -> Solved
cryIsGeq = pBin PGeq (>=)
  -- XXX: max a 10 >= 2 --> True
  -- XXX: max a 2 >= 10 --> a >= 10


pBin :: PC -> (Nat' -> Nat' -> Bool) -> Map TVar Interval ->
                                          Type -> Type -> Solved
pBin tf p _i t1 t2
  | Just e <- tIsError t1  = Unsolvable e
  | Just e <- tIsError t2  = Unsolvable e
  | Just x <- tIsNat' t1
  , Just y <- tIsNat' t2 =
      if p x y
        then SolvedIf []
        else Unsolvable $ TCErrorMessage
                        $ "Predicate " ++ show (pp tf) ++ " does not hold for "
                              ++ show x ++ " and " ++ show y
pBin _ _ _ _ _ = Unsolved

--------------------------------------------------------------------------------


tryEqInf :: TVar -> Type -> Solved
tryEqInf tv ty =
  case tNoUser ty of
    TCon (TF TCAdd) [a,b]
      | Just n <- tIsNum a, n >= 1
      , Just v <- tIsVar b, tv == v -> SolvedIf [ TVar tv =#= tInf ]
    _ -> Unsolved

tryEqK :: Nat' -> Type -> Solved
tryEqK lk ty =
  case tNoUser ty of
    TCon (TF f) [ a, b ] | Just rk <- tIsNat' a ->
      case f of

        TCAdd ->
          case (lk,rk) of
            (_,Inf) -> Unsolved -- shouldn't happen, as `inf + x ` inf`
            (Inf, Nat _) -> SolvedIf [ b =#= tInf ]
            (Nat lk', Nat rk')
              | lk' >= rk'  -> SolvedIf [ b =#= tNum (lk' - rk') ]
              | otherwise -> Unsolvable
                $ TCErrorMessage
                $ "Adding " ++ show rk' ++ " will always exceed "
                            ++ show lk'

        TCMul ->
          case (lk,rk) of
            (Inf,Inf)    -> SolvedIf [ b >== tOne ]
            (Inf,Nat _)  -> SolvedIf [ b =#= tInf ]
            (Nat 0, Inf) -> SolvedIf [ b =#= tZero ]
            (Nat k, Inf) -> Unsolvable
                          $ TCErrorMessage $ show k ++ " /= inf * anything"
            (Nat lk', Nat rk')
              | rk' == 0 -> Unsolved --- shouldn't happen, as `0 * x = x`
              | (q,0) <- divMod lk' rk' -> SolvedIf [ b =#= tNum q ]
              | otherwise -> Unsolvable
                $ TCErrorMessage
                $ show lk ++ " /= " ++ show rk ++ " * anything"

        -- XXX: Min, Max, etx
        -- 2  = min (10,y)  --> y = 2
        -- 2  = min (2,y)   --> y >= 2
        -- 10 = min (2,y)   --> impossible
        _ -> Unsolved


    _ -> Unsolved




-- | When given an equality constraint, attempt to rewrite it to the form `?x =
-- ...`, by moving all occurrences of `?x` to the LHS, and any other variables
-- to the RHS.  This will only work when there's only one unification variable
-- present in the prop.

tryRewrteEqAsSubst :: Map TVar Interval -> Type -> Type -> Maybe (TVar,Type)
tryRewrteEqAsSubst fins t1 t2 =
  do let vars = Set.toList (Set.filter isFreeTV (fvs (t1,t2)))
     listToMaybe $ sortBy (flip compare `on` rank)
                 $ catMaybes [ tryRewriteEq fins var t1 t2 | var <- vars ]


-- | Rank a rewrite, favoring expressions that have fewer subtractions than
-- additions.
rank :: (TVar,Type) -> Int
rank (_,ty) = go ty
  where

  go (TCon (TF TCAdd) ts) = sum (map go ts) + 1
  go (TCon (TF TCSub) ts) = sum (map go ts) - 1
  go (TCon (TF TCMul) ts) = sum (map go ts) + 1
  go (TCon (TF TCDiv) ts) = sum (map go ts) - 1
  go (TCon _          ts) = sum (map go ts)
  go _                    = 0


-- | Rewrite an equation with respect to a unification variable ?x, into the
-- form `?x = t`.  There are two interesting cases to consider (four with
-- symmetry):
--
--  * ?x = ty
--  * expr containing ?x = expr
--
-- In the first case, we just return the type variable and the type, but in the
-- second we try to rewrite the equation until it's in the form of the first
-- case.
tryRewriteEq :: Map TVar Interval -> TVar -> Type -> Type -> Maybe (TVar,Type)
tryRewriteEq fins uvar l r =
  msum [ do guard (uvarTy == l && uvar `Set.notMember` rfvs)
            return (uvar, r)

       , do guard (uvarTy == r && uvar `Set.notMember` lfvs)
            return (uvar, l)

       , do guard (uvar `Set.notMember` rfvs)
            ty <- rewriteLHS fins uvar l r
            return (uvar,ty)

       , do guard (uvar `Set.notMember` lfvs)
            ty <- rewriteLHS fins uvar r l
            return (uvar,ty)
       ]

  where

  uvarTy = TVar uvar

  lfvs   = fvs l
  rfvs   = fvs r


-- | Check that a type contains only finite type variables.
allFin :: Map TVar Interval -> Type -> Bool
allFin ints ty = iIsFin (typeInterval ints ty)


-- | Rewrite an equality until the LHS is just `uvar`. Return the rewritten RHS.
--
-- There are a few interesting cases when rewriting the equality:
--
--  A o B = R  when `uvar` is only present in A
--  A o B = R  when `uvar` is only present in B
--
-- In the first case, as we only consider addition and subtraction, the
-- rewriting will continue on the left, after moving the `B` side to the RHS of
-- the equation.  In the second case, if the operation is addition, the `A` side
-- will be moved to the RHS, with rewriting continuing in `B`. However, in the
-- case of subtraction, the `B` side is moved to the RHS, and rewriting
-- continues on the RHS instead.
--
-- In both cases, if the operation is addition, rewriting will only continue if
-- the operand being moved to the RHS is known to be finite. If this check was
-- not done, we would end up violating the well-definedness condition for
-- subtraction (for a, b: well defined (a - b) iff fin b).
rewriteLHS :: Map TVar Interval -> TVar -> Type -> Type -> Maybe Type
rewriteLHS fins uvar = go
  where

  go (TVar tv) rhs | tv == uvar = return rhs

  go (TCon (TF tf) [x,y]) rhs =
    do let xfvs = fvs x
           yfvs = fvs y

           inX  = Set.member uvar xfvs
           inY  = Set.member uvar yfvs

       if | inX && inY -> mzero
          | inX        -> balanceR x tf y rhs
          | inY        -> balanceL x tf y rhs
          | otherwise  -> mzero


  -- discard type synonyms, the rewriting will make them no longer apply
  go (TUser _ _ l) rhs =
       go l rhs

  -- records won't work here.
  go _ _ =
       mzero


  -- invert the type function to balance the equation, when the variable occurs
  -- on the LHS of the expression `x tf y`
  balanceR x TCAdd y rhs = do guardFin y
                              go x (tSub rhs y)
  balanceR x TCSub y rhs = go x (tAdd rhs y)
  balanceR _ _     _ _   = mzero


  -- invert the type function to balance the equation, when the variable occurs
  -- on the RHS of the expression `x tf y`
  balanceL x TCAdd y rhs = do guardFin y
                              go y (tSub rhs x)
  balanceL x TCSub y rhs = go (tAdd rhs y) x
  balanceL _ _     _ _   = mzero


  -- guard that the type is finite
  --
  -- XXX this ignores things like `min x inf` where x is finite, and just
  -- assumes that it won't work.
  guardFin ty = guard (allFin fins ty)
