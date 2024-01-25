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

Some important methods that we have are the following (there are more but these are ones
that hold under certain conditions that are not so obvious, therefore I would like to
explicitly mention them):

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

## The router

The `Router` class is the main component of the twine system. Everything such as `Link` objects and so forth make a part of the
router's way or working. The router performs several core tasks which include:

1. Maintaining the routing table
    * This means we advertise all routes present in the routing table to other routers over the available links
    * It also means checking the routing table every _now and then_ for routes which ought to be expired
    * Receiving advertised routes from other nodes and checking if they should be installed into the table
2. Traffic management
    * Support for installing a message handler which will run whenever traffic detained to you arrives
    * Forwarding traffic on behalf of others; to its final destination
    * Allowing the sending of traffic to other nodes

### The routing table

The routing table is at the heart of handling egress and forward-intended traffic. It relatively simple as well,
infact this is the routing table itself:

```{.d}
// routing tables
private Route[string] routes;
private Mutex routesLock;
```

There are then several methods which manipulate this routing table by locking it, performing some action and then
releasing said lock:

| Method                                  | Description                                                      |
|-----------------------------------------|------------------------------------------------------------------|
| `Optional!(Route) findRoute(string)`    | Given the destination network-layer address this returns an `Optional` potentially containing the found `Route` |
| `installRoute(Route route)`             | Checks if the given route should be installed and, if so, installs it. |
| `dumpRoutes()`                          | This is a debugging method which prints out the routing table in ASCII form |
| `installSelfRoute()`                    | Installs a route to yourself (destination is the result of `getPublicKey()`) |
| `Route[] getRoutes()`                   | Returns a list of all the currently installed routes            |
| `routeSweep()`                          | Checks all routes and evicts those which have expired            |
| `advertiseLoop()`                       | Sends out modified routes from the routing table (with us as the `via`) on an interval whilst we are running |

#### The self-route

You would have seen the `installSelfRoute()` but are probably wondering what that is. Well, it is actually called
in the constructor (`this()`) and is there such that you will have a route in your routing table with a distance of
$0$ (meaning it will never be replaced) and with a destination to your public key. What this means is the the route
advertising mechanism will be able to advertise your presence to other routers - that's it.

```{.numberLines .d}
/** 
 * Installs a route to ourselves
 * which has a distance of `0`,
 * a destination of our public
 * key and no link
 */
private void installSelfRoute()
{
    Route selfR = Route(getPublicKey(), null, 0);
    installRoute(selfR);
}
```

As you can see it doesn't have much difference to it than any other route being installed, besides, perhaps - the fact
that its `Link` is null. This is such that when you call `isSelfRoute()` (on the `Route` struct) that it will report
itself as such.

#### Installing of routes

Let's take a closer look at `installRoute(Route route)` because I would like to explain the logic that is used
to determine whether or not a given route, received from an advertisement, is installed into the routing table
or not.

```{.numberLines .d}
private void installRoute(Route route)
{
    this.routesLock.lock();

    scope(exit)
    {
        this.routesLock.unlock();
    }

    Route* cr = route.destination() in this.routes;

    ...
```

Firstly as you have seen we lock the routing table mutex to make sure we don't get any inconsistent changes
to the routing table during usage (remember that we will be modifying it and others could be doing so as
well). We then also set a `scope(exit)` statement which means that upon any exiting of this level of scope
we will unlock the mutex. Lastly we then get a pointer to the `Route` in the table at the given key. Remember
the routing table was a `Route[string]` which means the `string`, _the key_, is the destination address
of the incoming route in this case. The _value_ would be the found `Route*` if any.

```{.numberLines .d}
    ...

    // if no such route installs, go ahead and install it
    if(cr is null)
    {
        this.routes[route.destination()] = route;
    }
```

As you can see above we first check if the pointer was `null`, which indicates no route to said destination
existed. Therefore we will then install the incoming route at that destination.

```{.numberLines .d}
    ...

    // if such a route exists, then only install it if it
    // has a smaller distance than the current route
    else
    {
        if(route.distance() < (*cr).distance())
        {
            this.routes[route.destination()] = route;
        }
        else
        {
            // if matched route is the same as incoming route
            // then simply refresh the current one
            if(*cr == route)
            {
                cr.refresh();
            }
        }
    }
}
```

However, if a route did exist then we need to check some things before we install it. Namely, we only install
the route if the predicate of $d(r_{incoming}) < d(r_{current})$ where $d(r_i)$ is the distance metric of a given
route $r_i$. If this is _not_ the case then we do not install the route. However, we do do a check to see if
the incoming route is identical (must have been the same router advertising a route we received from it earlier)
then we simply refresh it (reset its timer) instead of storing it again, if that is not the case we don't change
anything.

#### Advertising of routes

The advertising of routes is implemented in the `advertiseLoop()` which runs on its own thread and will wake up
at a fixed interval in order to perform two operations:

1. Checking for evicted routes
    * By calling `routeSweep()`
2. Sending out advertisements
    * This is explained below

---

We now analyze this loop below:

```{.numberLines .d}
// Check for and evict expired routes
routeSweep();

// advertise to all links
Link[] selected = getLinkMan().getLinks();
logger.info("Advertising to ", selected.length, " many links");
```

As we can see above we sweep the routing table firstly by a call to `routeSweep()`.

We also see how we are eneumerating all `Link`(s) which are attached to the router
(via its `LinkManager` (returned by `getLinkMan()`)). We would like to advertise all
the routes in our table over all of these links.

---

```{.numberLines .d}

// advertise each route in table
foreach(Route route; getRoutes())
{
    logger.info("Advertising route '", route, "'");
    string dst = route.destination();
    string via = this.getPublicKey(); // routes must be advertised as if they're from me now
    ubyte distance = route.distance();

    Advertisement advMesg = Advertisement.newAdvertisement(dst, via, distance);
    Message message;
    if(toMessage(advMesg, message))
    {
        logger.dbg("Sending advertisement on '", link, "'...");
        link.broadcast(message.encode()); // should have a return value for success or failure
        logger.info("Sent advertisement");
    }
    else
    {
        // todo, handle failure to encode
        logger.error("Failure to encode, developer error");
    }
}

...
```

The advertising of routes works as follows. Given a route $r_i$ in our routing table,
we construct a new route, $r_i_{out}$ of which has all the attributes of the current
route's ($r_i$'s) attributes **however** we update the `via` (or _gateway_) of $r_i_{out}$
to be that of our public key. Only _then_ do we send out the advertisment over the `Link`
in the form of a broadcast.