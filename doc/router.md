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

```{.numberLines .d}

    /** 
     * Constructs a route to a destination
     * over a given link with a given metric.
     *
     * The destination of this route is
     * directly reachable over the link.
     *
     * Params:
     *   dst = the destination network-layer
     * address
     *   link = the `Link`
     *   distance = the distance
     */
    this(string dst, Link link, ubyte distance)
    {
        this(dst, link, dst, distance);
    }

    /** 
     * Constructs a route to a destination
     * over a link with a given metric.
     *
     * This also let's you set the next-hop
     * gateway that should be used.
     *
     * Params:
     *   dst = the destination network-layer
     * address
     *   link = the `Link`
     *   via = the next-hop gateway's address
     *   distance = the distance
     */
    this(string dst, Link link, string via, ubyte distance, Duration expirationTime = dur!("seconds")(60))
    {
        this.dstKey = dst;
        this.ll = link;
        this.viaKey = via;
        this.dst = distance;

        this.lifetime = StopWatch(AutoStart.yes);
        this.expirationTime = expirationTime;
    }

    /** 
     * Is this route direct? As
     * in the destination is
     * directly reachable via
     * the gateway (i.e. the
     * destination matches the
     * gateway)
     *
     * Returns: `true` if so,
     * otherwise `false`
     */
    public bool isDirect()
    {
        return this.dstKey == this.viaKey; // todo, should we ever use cmp?
    }

    /** 
     * Checks if this route
     * has expired
     *
     * Returns: `true` if so,
     * `false` otherwise
     */
    public bool hasExpired()
    {
        return this.lifetime.peek() > this.expirationTime;
    }

    /** 
     * Resets the expiration
     * timer for this route
     */
    public void refresh()
    {
        this.lifetime.reset();
    }

    /** 
     * Retrieves this route's
     * destination address
     *
     * Returns: the address
     */
    public string destination()
    {
        return this.dstKey;
    }

    /** 
     * Retrieves this route's
     * associated link
     *
     * Returns: a `Link`, or
     * `null` if this is a 
     * self-route
     */
    public Link link()
    {
        return this.ll;
    }

    /** 
     * Retirns whether or not
     * this route is a self-route
     * (i.e. the link set was
     * `null`)
     *
     * Returns: `true` if so,
     * otherwise `false`
     */
    public bool isSelfRoute()
    {
        return this.ll is null;
    }

    /** 
     * Retrieves the gateway
     * of this route
     *
     * Returns: the gateway's
     * address
     */
    public string gateway()
    {
        return this.viaKey;
    }

    /** 
     * Retrieves the distance
     *
     * Returns: the distance
     * metric
     */
    public ubyte distance()
    {
        return this.dst;
    }

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