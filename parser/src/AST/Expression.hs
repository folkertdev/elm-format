{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}

module AST.Expression where

import AST.V0_16
import Data.Fix
import ElmFormat.Mapping

import AST.Pattern (Pattern)
import qualified AST.Variable as Var
import qualified Data.Map.Strict as Dict
import qualified Data.Maybe as Maybe
import qualified Reporting.Annotation as A
import qualified Reporting.Region as R


---- GENERAL AST ----

data UnaryOperator =
    Negative
    deriving (Eq, Show)


data LetDeclaration ns e
  = LetDefinition (Pattern ns) [C1 Before (Pattern ns)] Comments e
  | LetAnnotation (C1 After (Var.Ref ())) (C1 Before (Type ns))
  | LetComment Comment
  deriving (Eq, Show, Functor)

instance MapNamespace a b (LetDeclaration a e) (LetDeclaration b e) where
    mapNamespace f ld =
        case ld of
            LetDefinition first rest comments body -> LetDefinition (fmap (fmap f) first) (mapNamespace f rest) comments body
            LetAnnotation name typ -> LetAnnotation name (fmap (fmap $ fmap f) typ)
            LetComment comment -> LetComment comment

instance MapReferences a b (LetDeclaration a e) (LetDeclaration b e) where
    mapReferences fu fl = \case
        LetDefinition name args c e -> LetDefinition (mapReferences fu fl name) (mapReferences fu fl args) c e
        LetAnnotation name typ -> LetAnnotation name (mapReferences fu fl typ)
        LetComment c -> LetComment c


type Expr =
    Fix (AnnotatedExpression [UppercaseIdentifier] R.Region)

data BeforePredicate; data AfterPredicate; data BeforeBody; data AfterBody
data IfClause e =
    IfClause (C2 BeforePredicate AfterPredicate e) (C2 BeforeBody AfterBody e)
    deriving (Eq, Show, Functor)


data BinopsClause ns e =
    BinopsClause Comments (Var.Ref ns) Comments e
    deriving (Eq, Show, Functor)

instance MapNamespace a b (BinopsClause a e) (BinopsClause b e) where
    mapNamespace f (BinopsClause pre op post e) =
        BinopsClause pre (mapNamespace f op) post e

instance MapReferences a b (BinopsClause a e) (BinopsClause b e) where
    mapReferences fu fl (BinopsClause pre op post e) =
        BinopsClause pre (mapReferences fu fl op) post e


data CaseBranch ns e =
    CaseBranch
        { beforePattern :: Comments
        , beforeArrow :: Comments
        , afterArrow :: Comments
        , pattern :: Pattern ns
        , body :: e
        }
    deriving (Eq, Functor, Show)

instance MapNamespace a b (CaseBranch a e) (CaseBranch b e) where
    mapNamespace f (CaseBranch c1 c2 c3 p e) = CaseBranch c1 c2 c3 (mapNamespace f p) e

instance MapReferences a b (CaseBranch a e) (CaseBranch b e) where
    mapReferences fu fl (CaseBranch c1 c2 c3 p e) = CaseBranch c1 c2 c3 (mapReferences fu fl p) e


type Expr' =
    Expression [UppercaseIdentifier] Expr


newtype AnnotatedExpression ns ann e =
    AE (A.Annotated ann (Expression ns e))
    deriving (Eq, Show, Functor)


instance MapNamespace a b (AnnotatedExpression a ann e) (AnnotatedExpression b ann e) where
    mapNamespace f (AE (A.A ann e)) = AE $ A.A ann $ mapNamespace f e

instance MapNamespace a b (Fix (AnnotatedExpression a ann)) (Fix (AnnotatedExpression b ann)) where
    mapNamespace f = cata (Fix . mapNamespace f)

instance MapReferences a b (AnnotatedExpression a ann e) (AnnotatedExpression b ann e) where
    mapReferences fu fl (AE (A.A ann e)) = AE $ A.A ann $ mapReferences fu fl e

instance MapReferences a b (Fix (AnnotatedExpression a ann)) (Fix (AnnotatedExpression b ann)) where
    mapReferences fu fl = cata (Fix . mapReferences fu fl)


stripAnnotation :: Fix (AnnotatedExpression ns ann) -> Fix (Expression ns)
stripAnnotation (Fix (AE (A.A _ e))) = Fix $ fmap stripAnnotation e


dropAnnotation :: Fix (AnnotatedExpression ns ann) -> Expression ns (Fix (AnnotatedExpression ns ann))
dropAnnotation (Fix (AE (A.A _ e))) = e


mapAnnotation :: (a -> b) -> Fix (AnnotatedExpression ns a) -> Fix (AnnotatedExpression ns b)
mapAnnotation f (Fix (AE (A.A a e))) = Fix $ AE $ A.A (f a) $ fmap (mapAnnotation f) e


addAnnotation :: ann -> Fix (Expression ns) -> Fix (AnnotatedExpression ns ann)
addAnnotation ann (Fix e) = Fix $ AE $ A.A ann $ fmap (addAnnotation ann) e


instance MapNamespace a b (Fix (Expression a)) (Fix (Expression b)) where
    mapNamespace f = cata (Fix . mapNamespace f)

instance MapReferences a b (Fix (Expression a)) (Fix (Expression b)) where
    mapReferences fu fl = cata (Fix . mapReferences fu fl)


data BeforePattern; data BeforeArrow; data AfterArrow
data Expression ns e
    = Unit Comments
    | Literal Literal
    | VarExpr (Var.Ref ns)

    | App e [C1 Before e] FunctionApplicationMultiline
    | Unary UnaryOperator e
    | Binops e [BinopsClause ns e] Bool
    | Parens (C2 Before After e)

    | ExplicitList
        { terms :: Sequence e
        , trailingComments :: Comments
        , forceMultiline :: ForceMultiline
        }
    | Range (C2 Before After e) (C2 Before After e) Bool

    | Tuple [C2 Before After e] Bool
    | TupleFunction Int -- will be 2 or greater, indicating the number of elements in the tuple

    | Record
        { base :: Maybe (C2 Before After LowercaseIdentifier)
        , fields :: Sequence (Pair LowercaseIdentifier e)
        , trailingComments :: Comments
        , forceMultiline :: ForceMultiline
        }
    | Access e LowercaseIdentifier
    | AccessFunction LowercaseIdentifier

    | Lambda [C1 Before (Pattern ns)] Comments e Bool
    | If (IfClause e) [C1 Before (IfClause e)] (C1 Before e)
    | Let [LetDeclaration ns e] Comments e
    | Case (C2 Before After e, Bool) [CaseBranch ns e]

    -- for type checking and code gen only
    | GLShader String
    deriving (Eq, Show, Functor)


instance MapNamespace a b (Expression a e) (Expression b e) where
    mapNamespace f expr =
        case expr of
            VarExpr var -> VarExpr (mapNamespace f var)
            Binops left restOps multiline -> Binops left (mapNamespace f restOps) multiline
            Let decls pre body -> Let (mapNamespace f decls) pre body

            Unit c -> Unit c
            AST.Expression.Literal l -> AST.Expression.Literal l
            App f' args multiline -> App f' args multiline
            Unary op e -> Unary op e
            Parens e -> Parens e
            ExplicitList terms' post multiline -> ExplicitList terms' post multiline
            Range e1 e2 multiline -> Range e1 e2 multiline
            AST.Expression.Tuple es multiline -> AST.Expression.Tuple es multiline
            TupleFunction n -> TupleFunction n
            AST.Expression.Record b fs post multiline -> AST.Expression.Record b fs post multiline
            Access e field' -> Access e field'
            AccessFunction n -> AccessFunction n
            Lambda params pre body multi -> Lambda (mapNamespace f params) pre body multi
            If c1 elseIfs els -> If c1 elseIfs els
            Case (cond, m) branches -> Case (cond, m) (fmap (mapNamespace f) branches)
            GLShader s -> GLShader s


instance MapReferences a b (Expression a e) (Expression b e) where
    mapReferences fu fl expr =
        case expr of
            VarExpr var -> VarExpr (mapReferences fu fl var)
            Binops left restOps multiline -> Binops left (mapReferences fu fl restOps) multiline
            Let decls pre body -> Let (mapReferences fu fl decls) pre body

            Unit c -> Unit c
            AST.Expression.Literal l -> AST.Expression.Literal l
            App f' args multiline -> App f' args multiline
            Unary op e -> Unary op e
            Parens e -> Parens e
            ExplicitList terms' post multiline -> ExplicitList terms' post multiline
            Range e1 e2 multiline -> Range e1 e2 multiline
            AST.Expression.Tuple es multiline -> AST.Expression.Tuple es multiline
            TupleFunction n -> TupleFunction n
            AST.Expression.Record b fs post multiline -> AST.Expression.Record b fs post multiline
            Access e field' -> Access e field'
            AccessFunction n -> AccessFunction n
            Lambda params pre body multi -> Lambda (mapReferences fu fl params) pre body multi
            If c1 elseIfs els -> If c1 elseIfs els
            Case (cond, m) branches -> Case (cond, m) (fmap (mapReferences fu fl) branches)
            GLShader s -> GLShader s


bottomUp :: Functor f => (Fix f -> Fix f) -> Fix f -> Fix f
bottomUp f = cata (f . Fix)


type UsageCount ns = Dict.Map ns (Dict.Map String Int)


countUsages :: Ord ns => Expression ns (UsageCount ns) -> UsageCount ns
countUsages e' =
    let
        mergeUsage = Dict.unionsWith (Dict.unionWith (+))
        _sequence = fmap (\(C _ t) -> t)
        _pair (Pair (C _ k) (C _ v) _) = (k, v)
        _c (C _ e) = e
        _letDeclaration l =
            case l of
                LetDefinition _ _ _ e -> Just e
                _ -> Nothing
        countIfClause (IfClause a b) = mergeUsage [_c a, _c b]
        countCaseBranch (CaseBranch _ _ _ p e) = e
    in
    case e' of
        Unit _ -> Dict.empty
        Literal _ -> Dict.empty
        VarExpr (Var.VarRef ns (LowercaseIdentifier n)) -> Dict.singleton ns (Dict.singleton n 1)
        VarExpr (Var.TagRef ns (UppercaseIdentifier n)) -> Dict.singleton ns (Dict.singleton n 1)
        VarExpr (Var.OpRef _) -> Dict.empty
        App e args _ -> mergeUsage (e : fmap dropComments args)
        Unary _ e -> e
        Binops e ops _ -> mergeUsage (e : fmap (\(BinopsClause _ _ _ t) -> t) ops)
        Parens e -> _c e
        ExplicitList terms _ _ -> mergeUsage (_sequence terms)
        Range a b _ -> mergeUsage [_c a, _c b]
        Tuple terms _ -> mergeUsage (fmap _c terms)
        TupleFunction _ -> Dict.empty
        Record _ fields _ _ -> mergeUsage (fmap (snd . _pair) $ _sequence fields)
        Access e _ -> e
        AccessFunction _ -> Dict.empty
        Lambda _ _ e _ -> e
        If a rest (C _ e) -> mergeUsage (countIfClause a : e : fmap (countIfClause . dropComments) rest)
        Let defs _ e -> mergeUsage (e : Maybe.mapMaybe _letDeclaration defs)
        Case (e, _) branches -> mergeUsage (_c e : fmap countCaseBranch branches)
        GLShader _ -> Dict.empty
