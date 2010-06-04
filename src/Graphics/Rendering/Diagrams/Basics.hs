{-# LANGUAGE FlexibleContexts, FlexibleInstances, TypeFamilies, MultiParamTypeClasses, UndecidableInstances, GADTs #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Graphics.Rendering.Diagrams.Basics
-- Copyright   :  (c) Brent Yorgey 2010
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  byorgey@cis.upenn.edu
-- Stability   :  experimental
-- Portability :  portable
--
-- The core library of primitives forming the basis of an embedded
-- domain-specific language for describing and rendering diagrams.
--
-- Note that end users should rarely (if ever) need to import this
-- module directly; instead, import "Graphics.Rendering.Diagrams",
-- which re-exports most of the functionality from this module.
-- Library developers may occasionally wish to import this module
-- directly if they need direct access to something not re-exported by
-- "Graphics.Rendering.Diagrams".
--
-----------------------------------------------------------------------------

module Graphics.Rendering.Diagrams.Basics
       ( -- * Backends

         Backend(..)
       , Renderable(..)

         -- * Primtives

       , Prim(..)

         -- * Bounds

       , Bounds(..)

         -- * Diagrams

       , Diagram(..)

         -- ** Primitive operations
         -- $prim
       , rebase
       , atop

       , rebaseBounds
       ) where

import Graphics.Rendering.Diagrams.Transform
import Graphics.Rendering.Diagrams.Expressions

import Data.VectorSpace
import Data.Basis
import Data.MemoTrie

import qualified Data.Map as M
import Data.Monoid
import Control.Applicative hiding (Const)

(<>) :: Monoid m => m -> m -> m
(<>) = mappend

-- XXX TODO: add lots of actual diagrams to illustrate the
-- documentation!  Haddock supports \<\<inline image urls\>\>.

------------------------------------------------------------
-- Backends  -----------------------------------------------
------------------------------------------------------------

-- | Abstract diagrams are rendered to particular formats by /backends/.
--   Each backend must be an instance of the 'Backend' class, and comes
--   with an associated vector space and rendering environment.
class (HasLinearMap (BSpace b), HasLinearMap (Scalar (BSpace b)))
    => Backend b where
  type BSpace b  :: *           -- The vector space associated with this backend
  type Render b  :: *           -- The rendering environment used by this backend
  type Result b  :: *           -- The result of the rendering operation
  data Options b :: *           -- The rendering options for this backend
  -- | 'renderDia' is used to render a diagram using this backend.
  renderDia      :: b          -- ^ Backend token
                 -> Options b  -- ^ Backend-specific collection of rendering options
                 -> Diagram b  -- ^ Diagram to render
                 -> Result b   -- ^ Output of the rendering operation

-- Note: as of version 2.7.2, Haddock doesn't seem to support
-- documentation for associated types; hence the comments next to
-- BSpace, Render, etc. above are not Haddock comments.  Making them
-- Haddock comments by adding a carat causes Haddock to choke with a
-- parse error.  Hopefully at some point in the future Haddock will
-- support this, at which time this comment can be deleted and the
-- above comments made into proper Haddock comments.


-- | The 'Renderable' type class connects backends to primitives which
--   they know how to render.
class (Backend b, Transformable t) => Renderable t b where
  render :: b -> t -> Render b
  -- ^ Given a token representing the backend and a transformable
  --   object, render it in the appropriate rendering context.

  -- Note, the token is necessary for type inference: unifying Render
  -- b with something else will never work, since Render is not
  -- necessarily injective.

------------------------------------------------------------
--  Primitives  --------------------------------------------
------------------------------------------------------------

-- | A value of type @Prim b@ is an opaque (existentially quantified)
--   primitive which backend @b@ knows how to render.
data Prim b where
  Prim :: (BSpace b ~ TSpace t, Renderable t b) => t -> Prim b

-- Note that we also require the vector spaces for the backend and the
-- primitive to be the same; this is necessary since the rendering
-- backend may need to lapp some transformations to the primitive
-- after unpacking the existential package.

-- | The 'Transformable' instance for 'Prim' just pushes calls to
--   'transform' down through the 'Prim' constructor.
instance Backend b => Transformable (Prim b) where
  type TSpace (Prim b) = BSpace b
  transform v (Prim p) = Prim (transform v p)

-- | The 'Renderable' instance for 'Prim' just pushes calls to
--   'render' down through the 'Prim' constructor.
instance Backend b => Renderable (Prim b) b where
  render b (Prim p) = render b p

------------------------------------------------------------
--  Bounds  ------------------------------------------------
------------------------------------------------------------

-- | Every diagram comes equipped with a bounding function.
--   Intuitively, the bounding function for a diagram tells us the
--   minimum distance we have to go in any given direction to get to a
--   (hyper)plane entirely containing the diagram on one side of
--   it. Formally, given a vector @v@, it returns a scalar @s@ such
--   that
--
--     * for every vector @u@ with its endpoint inside the diagram,
--       if the projection of @u@ onto @v@ is @s' *^ v@, then @s' <= s@.
--
--     * @s@ is the smallest such scalar.
--
--   Essentially, bounding functions are a functional representation
--   of convex bounding regions.  The idea for this representation
--   came from Sebastian Setzer: see <http://byorgey.wordpress.com/2009/10/28/collecting-attributes/#comment-2030>.
--
--   XXX add some diagrams here to illustrate!  Note that Haddock supports
--   inline images, using a \<\<url\>\> syntax.
newtype Bounds v = Bounds (v -> Scalar v)

-- | Bounding functions form a monoid, with the constantly zero
--   function (/i.e./ the empty region) as the identity, and pointwise
--   maximum as composition.  Hence, if @b1@ is the bounding function
--   for diagram @d1@, and @b2@ is the bounding function for @d2@,
--   then @b1 \`mappend\` b2@ is the bounding function for @d1
--   \`atop\` d2@.
instance (Ord (Scalar v), AdditiveGroup (Scalar v)) => Monoid (Bounds v) where
  mempty = Bounds $ const zeroV
  mappend (Bounds b1) (Bounds b2) = Bounds $ max <$> b1 <*> b2

------------------------------------------------------------
--  Diagrams  ----------------------------------------------
------------------------------------------------------------

-- | The basic 'Diagram' data type.  A diagram consists of a list of
--   primitives, a functional convex bounding region, and a set of
--   named (local) points.
data Diagram b = Diagram { prims  :: [Prim b]
                         , bounds :: Bounds (BSpace b)
                         , names  :: NameSet (BSpace b)
                         }

------------------------------------------------------------
--  Primitive operations  ----------------------------------
------------------------------------------------------------

-- | @'rebase' u d@ is the same as @d@, except with the local origin
--   moved to @u@.
rebase :: ( Backend b, v ~ BSpace b
          , InnerSpace v, HasLinearMap v, HasLinearMap (Scalar v)
          , AdditiveGroup (Scalar v), Fractional (Scalar v)
          , Scalar (Scalar v) ~ Scalar v)
       => LExpr v -> Diagram b -> Diagram b
rebase e (Diagram ps b (NameSet s))
  = Diagram { prims  = map (translate (negateV u)) ps
            , bounds = rebaseBounds u b
            , names  = NameSet $ M.map (map (^-^ u)) s
            }
  where u = evalLExpr e (NameSet s)

-- | Rebase a bounding function, that is, change the local origin with
--   respect to which bounding queries are made.
rebaseBounds :: (InnerSpace v, AdditiveGroup (Scalar v), Fractional (Scalar v))
             => v -> Bounds v -> Bounds v
rebaseBounds u (Bounds f) = Bounds $ \v -> f v ^-^ ((u ^/ (v <.> v)) <.> v)

-- | 'Diagram's can be transformed by transforming each of their
--   components appropriately.
instance ( Backend b
         , InnerSpace (BSpace b)
         , Scalar (Scalar (BSpace b)) ~ Scalar (BSpace b)
         , Floating (Scalar (BSpace b)))
    => Transformable (Diagram b) where
  type TSpace (Diagram b) = BSpace b
  transform t (Diagram ps (Bounds b) (NameSet ns))
    = Diagram (map (transform t) ps)
              -- XXX this is still wrong for transformations that don't preserve angle!
              (Bounds $ b . apply (inv t))
              (NameSet $ M.map (map (apply t)) ns)

-- | Compose two diagrams by aligning their respective local origins.
--   The new diagram has all the primitives and all the names from the
--   two diagrams combined.  Put the first on top of the second (when
--   such a notion makes sense in the digrams' vector space, such as
--   R2; in other vector spaces, like R3, 'atop' is commutative).
atop :: (s ~ Scalar (BSpace b), Ord s, AdditiveGroup s)
     => Diagram b -> Diagram b -> Diagram b
atop (Diagram ps1 bs1 ns1) (Diagram ps2 bs2 ns2) =
  Diagram (ps1 <> ps2) (bs1 <> bs2) (ns1 <> ns2)

-- | Diagrams form a monoid since each of their three components do:
--   the empty diagram has no primitives, a constantly zero bounding
--   function, and no named points; diagrams compose via 'atop'.
instance (s ~ Scalar (BSpace b), Ord s, AdditiveGroup s) => Monoid (Diagram b) where
  mempty  = Diagram mempty mempty mempty
  mappend = atop
