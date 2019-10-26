{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}

module ElmFormat.Mapping where

import AST.V0_16

import qualified Reporting.Annotation as A


-- New AST:
-- parameters:
--    namespace :: [UppercaseIdentifier]
--      typeRef :: (namespace, UppercaseIdentifier)
--      varRef :: Var.Ref namespace

-- these should be functors?
--    annotation :: Region
--
--    comment :: Comments
--    eol :: Maybe String (should this include the Maybe?  I guess so because if we strip it to (), then there shouldn't be a Maybe)

-- these are recursive
--    expression :: Expr
--    type :: Type
--    pattern :: Pattern


class MapNamespace ns1 ns2 a1 a2 where
    mapNamespace :: (ns1 -> ns2) -> a1 -> a2

instance MapNamespace a b t1 t2 => MapNamespace a b (A.Annotated ann t1) (A.Annotated ann t2) where
    mapNamespace f (A.A ann t) = A.A ann (mapNamespace f t)
    {-# INLINE mapNamespace #-}

instance MapNamespace a b t1 t2 => MapNamespace a b (Commented c t1) (Commented c t2) where
    mapNamespace f = fmap (mapNamespace f)
    {-# INLINE mapNamespace #-}

instance MapNamespace a b t1 t2 => MapNamespace a b (List t1) (List t2) where
    mapNamespace f = fmap (mapNamespace f)
    {-# INLINE mapNamespace #-}

instance MapNamespace a b (Type' a) (Type' b) where
    mapNamespace = fmap
    {-# INLINE mapNamespace #-}



class MapReferences ns1 ns2 a1 a2 where
    mapReferences ::
        ((ns1, UppercaseIdentifier) -> (ns2, UppercaseIdentifier))
        -> ((ns1, LowercaseIdentifier) -> (ns2, LowercaseIdentifier))
        -> a1
        -> a2
    mapReferences' ::
        ( (ns1, UppercaseIdentifier) -> (ns2, UppercaseIdentifier)
        , (ns1, LowercaseIdentifier) -> (ns2, LowercaseIdentifier)
        )
        -> a1
        -> a2
    mapReferences' (fu, fl) = mapReferences fu fl
    {-# INLINE mapReferences' #-}

instance MapReferences a b t1 t2 => MapReferences a b (A.Annotated ann t1) (A.Annotated ann t2) where
    mapReferences fu fl (A.A ann t) = A.A ann (mapReferences fu fl t)
    {-# INLINE mapReferences #-}

instance MapReferences a b t1 t2 => MapReferences a b (Commented c t1) (Commented c t2) where
    mapReferences fu fl = fmap (mapReferences fu fl)
    {-# INLINE mapReferences #-}

instance MapReferences a b t1 t2 => MapReferences a b (Pair x t1) (Pair x t2) where
    mapReferences fu fl (Pair k v ml) = Pair k (mapReferences fu fl v) ml
    {-# INLINE mapReferences #-}

instance MapReferences a b t1 t2 => MapReferences a b (List t1) (List t2) where
    mapReferences fu fl = fmap (mapReferences fu fl)
    {-# INLINE mapReferences #-}

instance MapReferences a b (TypeConstructor a) (TypeConstructor b) where
    mapReferences fu _ (NamedConstructor name) = NamedConstructor (fu name)
    mapReferences _ _ (TupleConstructor n) = TupleConstructor n
    {-# INLINE mapReferences #-}

instance MapReferences a b (Type' a) (Type' b) where
    mapReferences fu fl = \case
        UnitType c -> UnitType c
        TypeVariable name -> TypeVariable name
        TypeConstruction ctor args -> TypeConstruction (mapReferences fu fl ctor) (mapReferences fu fl args)
        TypeParens t -> TypeParens (mapReferences fu fl t)
        TupleType ts -> TupleType (mapReferences fu fl ts)
        RecordType base fields c ml -> RecordType base (mapReferences fu fl fields) c ml
        FunctionType first rest ml -> FunctionType (mapReferences fu fl first) (mapReferences fu fl rest) ml



-- TODO: add MapAnnotation



class MapType t1 t2 a1 a2 where
    mapType :: (t1 -> t2) -> a1 -> a2

instance MapType a b t1 t2 => MapType a b (A.Annotated ann t1) (A.Annotated ann t2) where
    mapType f (A.A ann t) = A.A ann (mapType f t)
    {-# INLINE mapType #-}

instance MapType a b t1 t2 => MapType a b (Commented c t1) (Commented c t2) where
    mapType f = fmap (mapType f)
    {-# INLINE mapType #-}

instance MapType a b t1 t2 => MapType a b (Pair x t1) (Pair x t2) where
    mapType f (Pair k v ml) = Pair k (mapType f v) ml
    {-# INLINE mapType #-}

instance MapType a b t1 t2 => MapType a b (List t1) (List t2) where
    mapType f = fmap (mapType f)
    {-# INLINE mapType #-}

instance MapType (Type' ns) (Type' ns) (Type' ns) (Type' ns) where
    mapType f typ =
        -- This does a bottom-up traversal of the Type
        f $
        case typ of
            UnitType _ -> typ
            TypeVariable _ -> typ
            TypeConstruction ctor args -> TypeConstruction ctor (mapType f args)
            TypeParens t -> TypeParens (mapType f t)
            TupleType ts -> TupleType (mapType f ts)
            RecordType base fields cs ml -> RecordType base (mapType f fields) cs ml
            FunctionType first rest ml -> FunctionType (mapType f first) (mapType f rest) ml



class MapExpression e1 e2 a1 a2 where
    mapExpression :: (e1 -> e2) -> a1 -> a2
