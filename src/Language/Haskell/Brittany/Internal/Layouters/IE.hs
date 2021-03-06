module Language.Haskell.Brittany.Internal.Layouters.IE
  ( layoutIE
  , layoutLLIEs
  , layoutAnnAndSepLLIEs
  )
where

#include "prelude.inc"

import           Language.Haskell.Brittany.Internal.Types
import           Language.Haskell.Brittany.Internal.LayouterBasics
import           Language.Haskell.Brittany.Internal.Config.Types

import           GHC     ( unLoc
                         , runGhc
                         , GenLocated(L)
                         , moduleNameString
                         , AnnKeywordId(..)
                         , Located
                         )
import           HsSyn
import           Name
import           HsImpExp
import           FieldLabel
import qualified FastString
import           BasicTypes

import           Language.Haskell.Brittany.Internal.Utils



#if MIN_VERSION_ghc(8,2,0)
prepareName :: LIEWrappedName name -> Located name
prepareName = ieLWrappedName
#else
prepareName :: Located name -> Located name
prepareName = id
#endif

layoutIE :: ToBriDoc IE
layoutIE lie@(L _ ie) = docWrapNode lie $ case ie of
#if MIN_VERSION_ghc(8,6,0)
  IEVar _ x -> layoutWrapped lie x
#else
  IEVar x -> layoutWrapped lie x
#endif
#if MIN_VERSION_ghc(8,6,0)
  IEThingAbs _ x -> layoutWrapped lie x
#else
  IEThingAbs x -> layoutWrapped lie x
#endif
#if MIN_VERSION_ghc(8,6,0)
  IEThingAll _ _ -> docSeq [ienDoc, docLit $ Text.pack "(..)"]
#else
  IEThingAll _ -> docSeq [ienDoc, docLit $ Text.pack "(..)"]
#endif
#if MIN_VERSION_ghc(8,6,0)
  IEThingWith _ _ (IEWildcard _) _ _ ->
#else
  IEThingWith _ (IEWildcard _) _ _ ->
#endif
    docSeq [ienDoc, docLit $ Text.pack "(..)"]
#if MIN_VERSION_ghc(8,6,0)
  IEThingWith _ _ _ ns _ -> do
#else
  IEThingWith _ _ ns _ -> do
#endif
    hasComments <- hasAnyCommentsBelow lie
    runFilteredAlternative $ do
      addAlternativeCond (not hasComments)
        $  docSeq
        $  [ienDoc, docLit $ Text.pack "("]
        ++ intersperse docCommaSep (map nameDoc ns)
        ++ [docParenR]
      addAlternative $ docAddBaseY BrIndentRegular $ docPar
        ienDoc
        (layoutItems (splitFirstLast ns))
   where
    nameDoc = (docLit =<<) . lrdrNameToTextAnn . prepareName
    layoutItem n = docSeq [docCommaSep, docWrapNode n $ nameDoc n]
    layoutItems FirstLastEmpty = docSetBaseY $ docLines
      [docSeq [docParenLSep, docWrapNodeRest lie docEmpty], docParenR]
    layoutItems (FirstLastSingleton n) = docSetBaseY $ docLines
      [docSeq [docParenLSep, docWrapNodeRest lie $ nameDoc n], docParenR]
    layoutItems (FirstLast n1 nMs nN) =
      docSetBaseY
        $  docLines
        $  [docSeq [docParenLSep, docWrapNode n1 $ nameDoc n1]]
        ++ map layoutItem nMs
        ++ [docSeq [docCommaSep, docWrapNodeRest lie $ nameDoc nN], docParenR]
#if MIN_VERSION_ghc(8,6,0)
  IEModuleContents _ n -> docSeq
#else
  IEModuleContents n -> docSeq
#endif
    [ docLit $ Text.pack "module"
    , docSeparator
    , docLit . Text.pack . moduleNameString $ unLoc n
    ]
  _ -> docEmpty
 where
  ienDoc        = docLit =<< lrdrNameToTextAnn (ieName <$> lie)
#if MIN_VERSION_ghc(8,2,0) /* ghc-8.2, 8.4, .. */
  layoutWrapped _ = \case
    L _ (IEName    n) -> docLit =<< lrdrNameToTextAnn n
    L _ (IEPattern n) -> do
      name <- lrdrNameToTextAnn n
      docLit $ Text.pack "pattern " <> name
    L _ (IEType n) -> do
      name <- lrdrNameToTextAnn n
      docLit $ Text.pack "type " <> name
#else                      /* ghc-8.0 */
  layoutWrapped outer n = do
    name <- lrdrNameToTextAnn n
    hasType <- hasAnnKeyword n AnnType
    hasPattern <- hasAnnKeyword outer AnnPattern
    docLit $ if
      | hasType    -> Text.pack "type (" <> name <> Text.pack ")"
      | hasPattern -> Text.pack "pattern " <> name
      | otherwise  -> name
#endif

-- Helper function to deal with Located lists of LIEs.
-- In particular this will also associate documentation
-- from the located list that actually belongs to the last IE.
-- It also adds docCommaSep to all but the first element
-- This configuration allows both vertical and horizontal
-- handling of the resulting list. Adding parens is
-- left to the caller since that is context sensitive
layoutAnnAndSepLLIEs
  :: Located [LIE GhcPs] -> ToBriDocM [ToBriDocM BriDocNumbered]
layoutAnnAndSepLLIEs llies@(L _ lies) = do
  let makeIENode ie = docSeq [docCommaSep, ie]
  let ieDocs = layoutIE <$> lies
  ieCommaDocs <-
    docWrapNodeRest llies $ sequence $ case splitFirstLast ieDocs of
      FirstLastEmpty        -> []
      FirstLastSingleton ie -> [ie]
      FirstLast ie1 ieMs ieN ->
        [ie1] ++ map makeIENode ieMs ++ [makeIENode ieN]
  pure $ fmap pure ieCommaDocs -- returned shared nodes

-- Builds a complete layout for the given located
-- list of LIEs. The layout provides two alternatives:
-- (item, item, ..., item)
-- ( item
-- , item
-- ...
-- , item
-- )
-- If the llies contains comments the list will
-- always expand over multiple lines, even when empty:
-- () -- no comments
-- ( -- a comment
-- )
layoutLLIEs :: Bool -> Located [LIE GhcPs] -> ToBriDocM BriDocNumbered
layoutLLIEs enableSingleline llies = do
  ieDs        <- layoutAnnAndSepLLIEs llies
  hasComments <- hasAnyCommentsBelow llies
  runFilteredAlternative $
    case ieDs of
      [] -> do
        addAlternativeCond (not hasComments) $
          docLit $ Text.pack "()"
        addAlternativeCond hasComments $
          docPar (docSeq [docParenLSep, docWrapNodeRest llies docEmpty])
                 docParenR
      (ieDsH:ieDsT) -> do
        addAlternativeCond (not hasComments && enableSingleline)
          $  docSeq
          $  [docLit (Text.pack "(")]
          ++ (docForceSingleline <$> ieDs)
          ++ [docParenR]
        addAlternative
          $  docPar (docSetBaseY $ docSeq [docParenLSep, ieDsH])
          $  docLines
          $  ieDsT
          ++ [docParenR]
