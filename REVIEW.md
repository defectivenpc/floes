# Review

question the need for link local mkfloe has out.k8s on the interface? Why?

why is mkfloe provides in two places? And why use it in two places in the
examples? I guess it would be good to not only depend on nixos modules.
Floes can work with or without them. Is that the intention?

kind terminology confusing. If it is just to be different from types or
signatures or options we need to sort that out.

DATABASE sig needs to be multiple not singular

What is `as` on a mkSig/sig?

How does link local and defered work anyway? Perhaps better terms to
represent runtime? Also do we need a better way to encapsulate and design a
better external/internal API of a floe

How do we make it safe for other services to read values that are collected
on a floe? Not clear from the networking sig example, and it isn't marked.
Unless link handles this automatically? Perhaps it would give a
better/faster implementation if we required marking any exposed field on a
floe that got that field from collection

I don't like the fields name on the sig. It is ambiguous whether it is
referring to input or output or internal.

Collects is like a requires, Can we build a dag. Detect cycles and then we
can determine the order to process it? Outlaw cycles but then we can safely
read from collected values
