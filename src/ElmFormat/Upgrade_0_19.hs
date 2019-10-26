{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

module ElmFormat.Upgrade_0_19 (UpgradeDefinition, transform, parseUpgradeDefinition, transformModule, mergeUpgradeImports, MatchedNamespace(..)) where

import Elm.Utils ((|>))

import AST.Annotated ()
import AST.V0_16
import AST.Declaration (Declaration(..), TopLevelStructure(..))
import AST.Expression
import AST.Module (Module(Module), ImportMethod(..), DetailedListing(..))
import AST.Pattern
import AST.Variable
import Control.Applicative ((<|>), liftA2)
import Control.Monad (zipWithM)
import Data.Fix
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import ElmFormat.ImportInfo (ImportInfo)
import ElmFormat.Mapping
import ElmVersion
import Reporting.Annotation (Annotated(A))

import qualified AST.Annotated as Annotated
import qualified Data.Bimap as Bimap
import qualified Data.List as List
import qualified Data.Map.Strict as Dict
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified ElmFormat.ImportInfo as ImportInfo
import qualified ElmFormat.Parse
import qualified ElmFormat.Version
import qualified Reporting.Annotation as RA
import qualified Reporting.Region as Region
import qualified Reporting.Result as Result


elm0_19upgrade :: Text.Text
elm0_19upgrade = Text.pack $ unlines
    [ "upgrade_Basics_flip f b a ="
    , "    f a b"
    , ""
    , "upgrade_Basics_curry f a b ="
    , "    f (a, b)"
    , ""
    , "upgrade_Basics_uncurry f (a, b) ="
    , "    f a b"
    , ""
    , "upgrade_Basics_rem dividend divisor ="
    , "    remainderBy divisor dividend"
    ]


data UpgradeDefinition =
    UpgradeDefinition
        { _replacements ::
            Dict.Map
                ([UppercaseIdentifier], String)
                (Fix (Expression (MatchedNamespace [UppercaseIdentifier])))
        , _typeReplacements ::
            Dict.Map
                ([UppercaseIdentifier], UppercaseIdentifier)
                ([LowercaseIdentifier], Type' (MatchedNamespace [UppercaseIdentifier]))
        , _imports :: Dict.Map [UppercaseIdentifier] (C1 Before ImportMethod)
        }
    deriving Show

knownContents :: UpgradeDefinition -> [UppercaseIdentifier] -> DetailedListing
knownContents upgradeDefinition ns =
    DetailedListing
        { values =
            Dict.fromList
            $ fmap (flip (,) (C ([], []) ()) . LowercaseIdentifier . snd)
            $ filter ((==) ns . fst)
            $ Dict.keys
            $ _replacements upgradeDefinition
        , operators = mempty
        , types =
            Dict.fromList
            $ fmap (flip (,) (C ([], []) (C [] ClosedListing)) . snd)
            $ filter ((==) ns . fst)
            $ Dict.keys
            $ _typeReplacements upgradeDefinition
        }


parseUpgradeDefinition :: Text.Text -> Either () UpgradeDefinition
parseUpgradeDefinition definitionText =
    case ElmFormat.Parse.parse Elm_0_19 definitionText of
        Result.Result _ (Result.Ok modu@(Module _ _ _ (C _ imports) body)) ->
            let
                importInfo = ImportInfo.fromModule (const mempty) modu

                makeName :: String -> Maybe ([UppercaseIdentifier], String)
                makeName name =
                    (\rev -> (UppercaseIdentifier <$> reverse (tail rev), head rev))
                        <$> reverse <$> splitOn '_' <$> List.stripPrefix "upgrade_" name

                makeTypeName :: UppercaseIdentifier -> Maybe ([UppercaseIdentifier], UppercaseIdentifier)
                makeTypeName (UppercaseIdentifier name) =
                    (\rev -> (UppercaseIdentifier <$> reverse (tail rev), UppercaseIdentifier $ head rev))
                        <$> reverse <$> splitOn '_' <$> List.stripPrefix "Upgrade_" name

                getExpressionReplacement def =
                    case def of
                        Entry (A _ (Definition (A _ (VarPattern (LowercaseIdentifier name))) [] _ upgradeBody)) ->
                            case makeName name of
                                Just functionName -> Just (functionName, stripAnnotation upgradeBody)
                                Nothing -> Nothing

                        Entry (A _ (Definition (A _ (VarPattern (LowercaseIdentifier name))) args comments upgradeBody)) ->
                            case makeName name of
                                Just functionName ->
                                    Just
                                        ( functionName
                                        , Fix $ Lambda args comments (stripAnnotation upgradeBody) False
                                        )

                                Nothing -> Nothing

                        _ ->
                            Nothing

                matchReferences' = matchReferences importInfo

                getTypeReplacement = \case
                    Entry (A _ (TypeAlias comments (C _ (name, args)) (C _ (A _ typ)))) ->
                        case makeTypeName name of
                            Just typeName ->
                                Just (typeName, (fmap dropComments args, mapReferences' matchReferences' typ))

                            Nothing -> Nothing

                    _ -> Nothing
            in
            Right $ UpgradeDefinition
                { _replacements = fmap (mapReferences' matchReferences') $ Dict.fromList $ Maybe.mapMaybe getExpressionReplacement body
                , _typeReplacements = Dict.fromList $ Maybe.mapMaybe getTypeReplacement body
                , _imports = imports
                }

        Result.Result _ (Result.Err _) ->
            Left ()


splitOn :: Eq a => a -> [a] -> [[a]]
splitOn c s =
    case dropWhile ((==) c) s of
        [] -> []
        s' ->
            w : splitOn c s''
            where
                (w, s'') =
                    break ((==) c) s'


transform :: ImportInfo -> Fix (AnnotatedExpression [UppercaseIdentifier] ()) -> Fix (AnnotatedExpression [UppercaseIdentifier] ())
transform importInfo =
    case parseUpgradeDefinition elm0_19upgrade of
        Right replacements ->
            mapReferences' (applyReferences importInfo)
                . mapAnnotation (const ())
                . transform' replacements importInfo
                . mapReferences' (matchReferences importInfo)

        Left () ->
            error "Couldn't parse upgrade definition"


transformModule :: UpgradeDefinition -> Module -> Module
transformModule upgradeDefinition modu@(Module a b c (C preImports originalImports) originalBody') =
    let
        importInfo =
            -- Note: this is the info used for matching references in the
            -- source file being transformed, and should NOT include
            -- the imports merged in from the upgrade definition
            ImportInfo.fromModule (knownContents upgradeDefinition) modu

        transformTopLevelStructure ::
            Annotated.TopLevelStructure (MatchedNamespace [UppercaseIdentifier]) Region.Region
            -> Annotated.TopLevelStructure (MatchedNamespace [UppercaseIdentifier]) Region.Region
        transformTopLevelStructure structure =
            let
                s' :: Annotated.TopLevelStructure (MatchedNamespace [UppercaseIdentifier]) Region.Region
                s' = mapType (transformType upgradeDefinition) structure
                s'' :: Annotated.TopLevelStructure (MatchedNamespace [UppercaseIdentifier]) Region.Region
                s'' = mapExpression (mapAnnotation (const noRegion') . transform' upgradeDefinition importInfo . mapAnnotation (\(_ :: Region.Region) -> ())) s'
            in
            s''

        expressionFromTopLevelStructure structure =
            case structure of
                Entry (A _ (Definition _ _ _ expr)) -> Just expr
                _ -> Nothing

        namespacesWithReplacements =
              Set.fromList $ fmap fst $ Dict.keys $ _replacements upgradeDefinition

        usages body =
            let
                collectExprs = Maybe.mapMaybe expressionFromTopLevelStructure body

                usages' =
                    Dict.unionsWith (Dict.unionWith (+)) $
                    fmap (cata countUsages . stripAnnotation) collectExprs
            in
            fmap (Dict.foldr (+) 0) usages'

        typeReplacementsByModule :: Dict.Map [UppercaseIdentifier] (Set UppercaseIdentifier)
        typeReplacementsByModule =
            Dict.fromListWith Set.union $ fmap (fmap Set.singleton) $ Dict.keys $ _typeReplacements upgradeDefinition

        removeTypes rem listing =
            case listing of
                OpenListing c -> OpenListing c
                ClosedListing -> ClosedListing
                ExplicitListing (DetailedListing vars ops typs) ml ->
                    let
                        typs' = Dict.withoutKeys typs rem
                    in
                    -- Note: The formatter will handle converting to a closed listing if nothing is left
                    ExplicitListing (DetailedListing vars ops typs') ml

        removeUpgradedExposings ns (C pre (ImportMethod alias exposing)) =
            C pre $
                ImportMethod alias (fmap (removeTypes $ fromMaybe Set.empty $ Dict.lookup ns typeReplacementsByModule) exposing)

        originalBody =
            mapReferences' (matchReferences importInfo) <$> originalBody'

        finalBody =
            fmap transformTopLevelStructure originalBody

        finalImports =
            mergeUpgradeImports
                (Dict.mapWithKey removeUpgradedExposings originalImports)
                (_imports upgradeDefinition)
                namespacesWithReplacements
                (usages finalBody)

        finalImportInfo =
            ImportInfo.fromImports (const mempty) $ fmap dropComments finalImports
    in
    finalBody
        |> fmap (mapReferences' (applyReferences finalImportInfo))
        |> Module a b c (C preImports finalImports)


mergeUpgradeImports ::
    Dict.Map [UppercaseIdentifier] (C1 before ImportMethod)
    -> Dict.Map [UppercaseIdentifier] (C1 before ImportMethod)
    -> Set.Set [UppercaseIdentifier]
    -> Dict.Map (MatchedNamespace [UppercaseIdentifier]) Int
    -> Dict.Map [UppercaseIdentifier] (C1 before ImportMethod)
mergeUpgradeImports originalImports upgradeImports upgradesAttempted usagesAfter =
    let
        -- uBefore ns = Maybe.fromMaybe 0 $ Dict.lookup (MatchedImport ns) usagesBefore
        uAfter ns = Maybe.fromMaybe 0 $ Dict.lookup (MatchedImport ns) usagesAfter
    in
    Dict.union
        (Dict.filterWithKey (\k _ -> uAfter k > 0 || not (Set.member k upgradesAttempted)) originalImports)
        (Dict.filterWithKey (\k _ -> uAfter k > 0) upgradeImports)


data MatchedNamespace t
    = NoNamespace
    | MatchedImport t
    | Unmatched t
    deriving (Eq, Ord, Show)


matchReferences ::
    ImportInfo
    -> ( ([UppercaseIdentifier], UppercaseIdentifier) -> (MatchedNamespace [UppercaseIdentifier], UppercaseIdentifier)
       , ([UppercaseIdentifier], LowercaseIdentifier) -> (MatchedNamespace [UppercaseIdentifier], LowercaseIdentifier)
       )
matchReferences importInfo =
    let
        aliases = Bimap.toMap $ ImportInfo._aliases importInfo
        imports = ImportInfo._directImports importInfo
        exposed =
            Dict.union
                (Dict.mapKeys Left $ ImportInfo._exposed importInfo)
                (Dict.mapKeys Right $ ImportInfo._exposedTypes importInfo)

        f ns identifier =
            case ns of
                [] ->
                    case Dict.lookup identifier exposed of
                        Nothing -> NoNamespace
                        Just exposedFrom -> MatchedImport exposedFrom

                _ ->
                    let
                        self =
                            if Set.member ns imports then
                                Just ns
                            else
                                Nothing

                        fromAlias =
                            case ns of
                                [single] ->
                                    Dict.lookup single aliases
                                _ ->
                                    Nothing

                        resolved =
                            fromAlias <|> self
                    in
                    case resolved of
                        Nothing -> Unmatched ns
                        Just single -> MatchedImport single
    in
    ( \(ns, u) -> (f ns (Right u), u)
    , \(ns, l) -> (f ns (Left l), l)
    )


applyReferences ::
    ImportInfo
    -> ( (MatchedNamespace [UppercaseIdentifier], UppercaseIdentifier) -> ([UppercaseIdentifier], UppercaseIdentifier)
       , (MatchedNamespace [UppercaseIdentifier], LowercaseIdentifier) -> ([UppercaseIdentifier], LowercaseIdentifier)
       )
applyReferences importInfo =
    let
        aliases = Bimap.toMapR $ ImportInfo._aliases importInfo
        exposed =
            Dict.union
                (Dict.mapKeys Left $ ImportInfo._exposed importInfo)
                (Dict.mapKeys Right $ ImportInfo._exposedTypes importInfo)

        f ns' identifier =
            case ns' of
                NoNamespace -> []
                MatchedImport ns ->
                    case Dict.lookup identifier exposed of
                        Just exposedFrom | exposedFrom == ns -> []
                        _ -> Maybe.fromMaybe ns $ fmap pure $ Dict.lookup ns aliases
                Unmatched name -> name
    in
    ( \(ns, u) -> (f ns (Right u), u)
    , \(ns, l) -> (f ns (Left l), l)
    )


data Source
    = FromUpgradeDefinition
    | FromSource


{- An expression annotated with a Source -- this type is used throughout the upgrade transformation. -}
type UExpr = Fix (AnnotatedExpression (MatchedNamespace [UppercaseIdentifier]) Source)


transform' ::
    UpgradeDefinition
    -> ImportInfo
    -> Fix (AnnotatedExpression (MatchedNamespace [UppercaseIdentifier]) ()) -> Fix (AnnotatedExpression (MatchedNamespace [UppercaseIdentifier]) Source)
transform' upgradeDefinition importInfo =
    bottomUp (simplify . applyUpgrades upgradeDefinition importInfo) . mapAnnotation (const FromSource)


transformType ::
    UpgradeDefinition
    -> Type' (MatchedNamespace [UppercaseIdentifier])
    -> Type' (MatchedNamespace [UppercaseIdentifier])
transformType upgradeDefinition typ = case typ of
    TypeConstruction (NamedConstructor (MatchedImport ctorNs, ctorName)) args ->
        case Dict.lookup (ctorNs, ctorName) (_typeReplacements upgradeDefinition) of
            Just (argOrder, newTyp) ->
                let
                    inlines =
                        Dict.fromList $ zip argOrder (fmap (RA.drop . dropComments) args)
                in
                mapType (inlineTypeVars inlines) newTyp

            Nothing -> typ

    _ -> typ


applyUpgrades :: UpgradeDefinition -> ImportInfo -> UExpr -> UExpr
applyUpgrades upgradeDefinition importInfo expr =
    let
        exposed = ImportInfo._exposed importInfo
        replacements = _replacements upgradeDefinition

        replace :: Ref (MatchedNamespace [UppercaseIdentifier]) -> Maybe (Fix (Expression (MatchedNamespace [UppercaseIdentifier])))
        replace var =
            case var of
                VarRef NoNamespace (LowercaseIdentifier name) ->
                    Dict.lookup ([UppercaseIdentifier "Basics"], name) replacements

                VarRef (MatchedImport ns) (LowercaseIdentifier name) ->
                    Dict.lookup (ns, name) replacements

                TagRef (MatchedImport ns) (UppercaseIdentifier name) ->
                    Dict.lookup (ns, name) replacements

                OpRef (SymbolIdentifier "!") ->
                    Just $ Fix $
                    Lambda
                      [makeArg "model", makeArg "cmds"] []
                      (Fix $ Binops
                          (makeVarRef "model")
                          [BinopsClause [] var [] (makeVarRef "cmds")]
                          False
                      )
                      False

                OpRef (SymbolIdentifier "%") ->
                    Just $ Fix $
                    Lambda
                      [makeArg "dividend", makeArg "modulus"] []
                      (Fix $ App
                          (makeVarRef "modBy")
                          [ C [] $ makeVarRef "modulus"
                          , C [] $ makeVarRef "dividend"
                          ]
                          (FAJoinFirst JoinAll)
                      )
                      False

                _ -> Nothing

        makeTuple :: Int -> Fix (Expression (MatchedNamespace ns))
        makeTuple n =
            let
                vars =
                  if n <= 26
                    then fmap (\c -> [c]) (take n ['a'..'z'])
                    else error (pleaseReport'' "UNEXPECTED TUPLE" "more than 26 elements")
            in
                Fix $ Lambda
                    (fmap makeArg vars)
                    []
                    (Fix $ AST.Expression.Tuple (fmap (\v -> C ([], []) (makeVarRef v)) vars) False)
                    False
    in
    case unFix expr of
        AE (A _ (VarExpr var)) ->
            Maybe.fromMaybe expr $ fmap (addAnnotation FromUpgradeDefinition) $ replace var

        AE (A _ (TupleFunction n)) ->
            addAnnotation FromUpgradeDefinition $ makeTuple n

        AE (A ann (ExplicitList terms' trailing multiline)) ->
            let
                ha = (fmap UppercaseIdentifier ["Html", "Attributes"])
                styleExposed = Dict.lookup (LowercaseIdentifier "style") exposed == Just ha
            in
            Fix $ AE $ A ann $ ExplicitList (concat $ fmap (expandHtmlStyle styleExposed) $ terms') trailing multiline

        _ ->
            expr


simplify :: UExpr -> UExpr
simplify expr =
    let
        isElmFixRemove (C _ (Fix (AE (A FromUpgradeDefinition (VarExpr (VarRef (MatchedImport [UppercaseIdentifier "ElmFix"]) (LowercaseIdentifier "remove")))))))= True
        isElmFixRemove (C _ (Fix (AE (A FromUpgradeDefinition (VarExpr (VarRef (Unmatched [UppercaseIdentifier "ElmFix"]) (LowercaseIdentifier "remove")))))))= True
        isElmFixRemove _ = False
    in
    case unFix expr of
        -- apply arguments to special functions (like literal lambdas)
        AE (A source (App fn args multiline)) ->
            simplifyFunctionApplication source fn args multiline

        -- Remove ElmFix.remove from lists
        AE (A source (ExplicitList terms' trailing multiline)) ->
            Fix $ AE $ A source $ ExplicitList
                (filter (not . isElmFixRemove) terms')
                trailing
                multiline

        -- Inline field access of a literal record
        AE (A FromUpgradeDefinition (Access e field)) ->
            case e of
                Fix (AE (A _ (AST.Expression.Record _ fs _ _))) ->
                    case List.find (\(C _ (Pair (C _ f) _ _)) -> f == field) fs of
                        Nothing ->
                            expr
                        Just (C _ (Pair _ (C _ fieldValue) _)) ->
                            fieldValue
                _ ->
                    expr

        -- reduce if expressions with a literal bool condition
        AE (A FromUpgradeDefinition (If (IfClause (C (preCond, postCond) cond) (C (preIf, postIf) ifBody)) [] (C preElse elseBody))) ->
            destructureFirstMatch (C preCond cond)
                [ (C [] $ noRegion $ AST.Pattern.Literal $ Boolean True, ifBody) -- TODO: not tested
                , (C [] $ noRegion $ AST.Pattern.Literal $ Boolean False, elseBody)
                ]
                expr

        -- reduce case expressions
        AE (A FromUpgradeDefinition (Case (C (pre, post) term, _) branches)) ->
            let
                makeBranch (CaseBranch prePattern postPattern _ p1 b1) =
                    (C prePattern p1, b1)
            in
            destructureFirstMatch (C pre term)
                (fmap makeBranch branches)
                expr

        _ ->
            expr


expandHtmlStyle :: Bool -> C2Eol preComma pre UExpr -> [C2Eol preComma pre UExpr]
expandHtmlStyle styleExposed (C (preComma, pre, eol) term) =
    let
        lambda fRef =
            addAnnotation FromUpgradeDefinition $ Fix $
            Lambda
                [(C [] $ noRegion $ AST.Pattern.Tuple [makeArg' "a", makeArg' "b"]) ] []
                (Fix $ App
                    (Fix $ VarExpr $ fRef)
                    [ (C [] $ makeVarRef "a")
                    , (C [] $ makeVarRef "b")
                    ]
                    (FAJoinFirst JoinAll)
                )
                False

        isHtmlAttributesStyle var =
            case var of
                VarRef (MatchedImport [UppercaseIdentifier "Html", UppercaseIdentifier "Attributes"]) (LowercaseIdentifier "style") -> True
                VarRef NoNamespace (LowercaseIdentifier "style") -> styleExposed
                _ -> False
    in
    case dropAnnotation term of
        App (Fix (AE (A _ (VarExpr var)))) [C preStyle (Fix (AE (A _ (ExplicitList styles trailing _))))] _
          | isHtmlAttributesStyle var
          ->
            let
                convert (C (preComma', pre', eol') style) =
                    C
                        ( preComma ++ preComma'
                        , pre ++ preStyle ++ pre' ++ trailing ++ (Maybe.maybeToList $ fmap LineComment eol)
                        , eol'
                        )
                        (Fix $ AE $ A FromUpgradeDefinition $ App (lambda var) [C [] style] (FAJoinFirst JoinAll))
            in
            fmap convert styles

        _ ->
            [C (preComma, pre, eol) term]

--
-- Generic helpers
--


pleaseReport'' :: String -> String -> String
pleaseReport'' what details =
    "<elm-format-" ++ ElmFormat.Version.asString ++ ": "++ what ++ ": " ++ details ++ " -- please report this at https://github.com/avh4/elm-format/issues >"



nowhere :: Region.Position
nowhere =
    Region.Position 0 0


noRegion' :: Region.Region
noRegion' =
    Region.Region nowhere nowhere


noRegion :: a -> RA.Located a
noRegion =
    RA.at nowhere nowhere


makeArg :: String -> (C1 before (Pattern ns))
makeArg varName =
    (C [] $ noRegion $ VarPattern $ LowercaseIdentifier varName)


makeArg' :: String -> C2 before after (Pattern ns)
makeArg' varName =
    C ([], []) (noRegion $ VarPattern $ LowercaseIdentifier varName)


makeVarRef :: String -> Fix (Expression (MatchedNamespace any))
makeVarRef varName =
    Fix $ VarExpr $ VarRef NoNamespace $ LowercaseIdentifier varName


applyMappings :: Bool -> Dict.Map LowercaseIdentifier UExpr -> UExpr -> UExpr
applyMappings insertMultiline mappings =
    bottomUp simplify
        . mapAnnotation snd
        . bottomUp (inlineVars ((==) NoNamespace) insertMultiline mappings)
        . mapAnnotation ((,) False)


inlineVars ::
    (ns -> Bool)
    -> Bool
    -> Dict.Map LowercaseIdentifier (Fix (AnnotatedExpression ns ann))
    -> Fix (AnnotatedExpression ns (Bool, ann))
    -> Fix (AnnotatedExpression ns (Bool, ann))
inlineVars isLocal insertMultiline mappings expr =
    case unFix expr of
        AE (A _ (VarExpr (VarRef ns n))) | isLocal ns->
            case Dict.lookup n mappings of
                Just (Fix (AE (A ann e))) ->
                    Fix $ AE $ A (insertMultiline, ann) $
                    fmap (mapAnnotation ((,) False)) e

                Nothing ->
                    expr

        AE (A ann (AST.Expression.Tuple terms' multiline)) ->
            let
                requestedMultiline (C _ (Fix (AE (A (m, _) _)))) = m
                newMultiline = multiline || any requestedMultiline terms'
            in
            Fix $ AE $ A ann $ AST.Expression.Tuple terms' newMultiline

        -- TODO: handle expanding multiline in contexts other than tuples

        _ -> expr


inlineTypeVars ::
    Dict.Map LowercaseIdentifier (Type' ns)
    -> Type' ns
    -> Type' ns
inlineTypeVars mappings typ =
    case typ of
        TypeVariable ref ->
            case Dict.lookup ref mappings of
                Just replacement -> replacement
                Nothing -> typ

        _ -> typ


destructureFirstMatch :: C1 before UExpr -> [ (C1 before (Pattern (MatchedNamespace [UppercaseIdentifier])), UExpr) ] -> UExpr -> UExpr
destructureFirstMatch value choices fallback =
    -- If we find an option that Matches, use the first one we find.
    -- Otherwise, keep track of which ones *could* match -- if there is only one remaining, we can use that
    let
        resolve [] = fallback
        resolve [body] = body
        resolve _ = fallback -- TODO: could instead indicate which options the caller should keep

        destructureFirstMatch' [] othersPossible = resolve othersPossible
        destructureFirstMatch' ((pat, body):rest) othersPossible =
            case destructure pat value of
                Matches mappings ->
                    resolve (applyMappings False mappings body : othersPossible)

                CouldMatch ->
                    destructureFirstMatch' rest (body:othersPossible)

                DoesntMatch ->
                    destructureFirstMatch' rest othersPossible
    in
    destructureFirstMatch' choices []


withComments :: Comments -> UExpr -> Comments -> UExpr
withComments [] e [] = e
withComments pre e post = Fix $ AE $ A FromUpgradeDefinition $ Parens $ C (pre, post) e


data DestructureResult a
    = Matches a
    | CouldMatch
    | DoesntMatch
    deriving (Functor, Show)


instance Applicative DestructureResult where
    pure a = Matches a

    liftA2 f (Matches a) (Matches b) = Matches (f a b)
    liftA2 _ (Matches _) CouldMatch = CouldMatch
    liftA2 _ CouldMatch (Matches _) = CouldMatch
    liftA2 _ CouldMatch CouldMatch = CouldMatch
    liftA2 _ _ DoesntMatch = DoesntMatch
    liftA2 _ DoesntMatch _ = DoesntMatch


instance Monad DestructureResult where
    (Matches a) >>= f = f a
    CouldMatch >>= _ = CouldMatch
    DoesntMatch >>= _ = DoesntMatch


{-| Returns `Nothing` if the pattern doesn't match, or `Just` with a list of bound variables if the pattern does match. -}
destructure :: C1 before (Pattern (MatchedNamespace [UppercaseIdentifier])) -> C1 before UExpr -> DestructureResult (Dict.Map LowercaseIdentifier UExpr)
destructure pat arg =
    let
        namespaceMatch nsd ns =
            case (nsd, ns) of
                (Unmatched nsd', MatchedImport ns') -> nsd' == ns'
                _ -> nsd == ns
    in
    case (pat, fmap dropAnnotation arg) of
        -- Parens in expression
        ( _
          , C preArg (AST.Expression.Parens (C (pre, post) inner))
          )
          ->
            destructure pat (C (preArg ++ pre ++ post) inner)

        -- Parens in pattern
        ( C preVar (A _ (PatternParens (C (pre, post) inner)))
          , _
          )
          ->
            destructure (C (preVar ++ pre ++ post) inner) arg

        -- Wildcard `_` pattern
        ( C _ (A _ Anything), _ ) -> Matches Dict.empty

        -- Unit
        ( C preVar (A _ (UnitPattern _))
          , C preArg (AST.Expression.Unit _)
          )
          ->
            Matches Dict.empty

        -- Literals
        ( C preVar (A _ (AST.Pattern.Literal pat))
          , C preArg (AST.Expression.Literal val)
          )
          ->
            -- TODO: handle ints/strings that are equal but have different representations
            if pat == val then
                Matches Dict.empty
            else
                DoesntMatch

        -- Custom type variants with no arguments
        ( C preVar (A _ (Data (nsd, name) []))
          , C preArg (VarExpr (TagRef ns tag))
          )
          ->
            if name == tag && namespaceMatch nsd ns then
                Matches Dict.empty
            else
                DoesntMatch

        -- Custom type variants with arguments
        ( C preVar (A _ (Data (nsd, name) argVars))
          , C preArg (App (Fix (AE (A _ (VarExpr (TagRef ns tag))))) argValues _)
          )
          ->
            if name == tag && namespaceMatch nsd ns then
                Dict.unions <$> zipWithM destructure argVars argValues
            else
                DoesntMatch

        -- Custom type variants where pattern and value don't match in having args
        ( C _ (A _ (Data _ (_:_))), C _ (VarExpr (TagRef _ _)) ) -> DoesntMatch
        ( C _ (A _ (Data _ [])), C _ (App (Fix (AE (A _ (VarExpr (TagRef _ _))))) _ _) ) -> DoesntMatch

        -- Named variable pattern
        ( C preVar (A _ (VarPattern name))
          , C preArg arg'
          ) ->
            Matches $ Dict.singleton name (withComments (preVar ++ preArg) (dropComments arg) [])

        -- `<|` which could be parens in expression
        ( _
          , C preArg (AST.Expression.Binops e (BinopsClause pre (OpRef (SymbolIdentifier "<|")) post arg1 : rest) ml)
          )
          ->
            destructure pat (C preArg $ Fix $ AE $ A FromSource $ App e [(C (pre ++ post) $ Fix $ AE $ A FromSource $ Binops arg1 rest ml)] (FAJoinFirst JoinAll))

        -- Tuple with two elements (TODO: generalize this for all tuples)
        ( C preVar (A _ (AST.Pattern.Tuple [C (preA, postA) (A _ (VarPattern nameA)), C (preB, postB) (A _ (VarPattern nameB))]))
          , C preArg (AST.Expression.Tuple [C (preAe, postAe) eA, C (preBe, postBe) eB] _)
          ) ->
            Matches $ Dict.fromList
                [ (nameA, withComments (preVar ++ preArg) (withComments (preA ++ preAe) eA (postAe ++ postA)) [])
                , (nameB, withComments (preB ++ preBe) eB (postBe ++ postB))
                ]

        -- Record destructuring
        ( C preVar (A _ (AST.Pattern.Record varFields))
          , C preArg (AST.Expression.Record _ argFields _ _)
          ) ->
            let
                args :: Dict.Map LowercaseIdentifier UExpr
                args =
                    argFields
                        |> fmap dropComments
                        |> fmap (\(Pair (C _ k) (C _ v) _) -> (k, v))
                        |> Dict.fromList

                fieldMapping :: C2 before after LowercaseIdentifier -> Maybe (LowercaseIdentifier, UExpr)
                fieldMapping (C _ var) =
                    (,) var <$> Dict.lookup var args
            in
            Maybe.fromMaybe DoesntMatch $ fmap (Matches . Dict.fromList) $ sequence $ fmap fieldMapping varFields

        -- `as`
        ( C preVar (A _ (AST.Pattern.Alias (p, _) (_, varName)))
          , _
          ) ->
            fmap Dict.unions $ sequence
                [ destructure (C preVar $ noRegion $ VarPattern varName) arg
                , destructure (C [] p) arg
                ]

        -- TODO: handle other patterns

        _ ->
            CouldMatch


simplifyFunctionApplication :: Source -> UExpr -> [C1 before (UExpr)] -> FunctionApplicationMultiline -> UExpr
simplifyFunctionApplication appSource fn args appMultiline =
    case (unFix fn, args) of
        (AE (A lambdaSource (Lambda (pat:restVar) preBody body multiline)), arg:restArgs) ->
            case destructure pat arg of
                Matches mappings ->
                    let
                        newBody = applyMappings (appMultiline == FASplitFirst) mappings body

                        newMultiline =
                            case appMultiline of
                                FASplitFirst -> FASplitFirst
                                FAJoinFirst SplitAll -> FASplitFirst
                                FAJoinFirst JoinAll -> FAJoinFirst JoinAll
                    in
                    case restVar of
                        [] ->
                            -- we applied the argument and none are left, so remove the lambda
                            Fix $ AE $ A appSource $ App
                                (withComments preBody newBody [])
                                restArgs
                                newMultiline

                        _:_ ->
                            -- we applied this argument; try to apply the next argument
                            simplifyFunctionApplication appSource (Fix $ AE $ A lambdaSource $ Lambda restVar preBody newBody multiline) restArgs newMultiline
                _ ->
                    -- failed to destructure the next argument, so stop
                    Fix $ AE $ A appSource $ App fn args appMultiline


        (_, []) -> fn

        _ -> Fix $ AE $ A appSource $ App fn args appMultiline
