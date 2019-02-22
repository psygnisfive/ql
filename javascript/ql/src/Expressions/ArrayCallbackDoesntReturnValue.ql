/*
 * This query finds cases of calls to array methods which take callbacks that ought to
 * return a value, such as `map` or `filter`, but which are supplied with callbacks that
 * can possible return nothing at all.
 */

import javascript
import MethodApplicationExpr

from MethodApplicationExpr fa, FunctionRef gref
where
  isArrayCallbackMethodName(fa.getApplicationMethodName()) and
  fa.getAnApplicationArgument() = gref and
  not exists(gref.getReferent().getAReturnedExpr())
select fa, fa.getApplicationMethodName(), gref, gref.getReferent()
