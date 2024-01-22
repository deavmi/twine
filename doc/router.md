Routing and forwarding
======================

Routing is the process by which one announces their routes to others, whilst forwarding is
the usage of those learnt routes in order to facilitate the transfer of packets from one
endpoint to another through a network of inter-connected routers.

## A route

Before we can get into the process of routing we must first have a conception of a _route_
itself.

A route consists of the following items:

1. A _destination_
    * Describes to whom this route is for, i.e. a route to _who_
2. A _link_
    * The `Link` object over which we can reach this host
3. A _gateway_
    * This is who we would need to forward the packet _via_ in
    order to get the packet either to the final destination (in
    such a case the $gateway = destination$) _or_ the next-hop
    gateway that we must forward via ($gateway \neq destination$)
4. A _distance_
    * This is metric which doesn't affect _how_ packets are
    forwarded but rather how routes that have the same matching
    _destination_ are tie-broken.
    * Given routes $r= \{r_1, r_2\}$ and a function $d(r_i)$
    which returns the distance we shall install the route $r_i$
    which has the lowest distance, hence $r_{installed} = r_i where d(r_i) = min(d(r))$ (TODO: fix this maths)
5. A _timer_ and _lifetime_
    * We have _timer_ which ticks upwards and a _lifetime_
    which allows us to check when the $timer > lifetime$ which
    signifies that the route has expired, indicating that
    we should remove it from the routing table.

And in code this can be found as the `Route` struct shown below:

```{.numberLines .d}
/** 
 * Represents a route
 */
public struct Route
{
    private string dstKey; // destination
    private Link ll; // link to use
    private string viaKey; // gateway (can be empty)
    private ubyte dst; // distance

    private StopWatch lifetime; // timer
    private Duration expirationTime; // maximum lifetime

    ...
}
```

### Methods

Some important methods that we have:

| Method                 | Description                                                      |
|------------------------|------------------------------------------------------------------|
| `isDirect()`           | Returns `true` when $gateway = destination$, otherwise `false`   |
| `isSelfRoute()`        | Returns `true` if the `Link` is `null`, otherwise `false`        |

### Route equality

Lastly, route equality is something that is checked as part of the router's code, so we
should probably show how we have overrode the `opEquals(Route)` method. This is the method
that is called when two `Route` structs are compared for equality using the `==` operator.

Our implementation goes as follows:

```{.numberLines .d}
public struct Route
{
    ...

    /** 
     * Compares two routes with one
     * another
     *
     * Params:
     *   r1 = first route
     *   r2 = second route
     * Returns: `true` if the routes
     * match exactly, otherwise `false`
     */
    public static bool isSameRoute(Route r1, Route r2)
    {

        return r1.destination() == r2.destination() &&
               r1.gateway() == r2.gateway() && 
               r1.distance() == r2.distance() &&
               r1.link() == r2.link();
    }

    /** 
     * Compares this `Route` with
     * another
     *
     * Params:
     *   rhs = the other route
     * Returns: `true` if the routes
     * are identical, `false` otherwise
     */
    public bool opEquals(Route rhs)
    {
        return isSameRoute(this, rhs);
    }
}
```