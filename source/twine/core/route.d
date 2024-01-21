module twine.core.route;

import twine.links.link;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.datetime : Duration, dur;

/** 
 * Represents a route
 */
public struct Route
{
    private string dstKey; // destination
    private Link ll; // link to use
    private string viaKey; // gateway (can be empty)
    private ubyte dst;

    private StopWatch lifetime;
    private Duration expirationTime;

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

    public bool hasExpired()
    {
        return this.lifetime.peek() > this.expirationTime;
    }

    public void refresh()
    {
        this.lifetime.reset();
    }

    public string destination()
    {
        return this.dstKey;
    }

    public Link link()
    {
        return this.ll;
    }

    public bool isSelfRoute()
    {
        return this.ll is null;
    }

    public string gateway()
    {
        return this.viaKey;
    }

    public ubyte distance()
    {
        return this.dst;
    }

    // two routes are considered the same if they
    // are to the same destination using the same
    // gateway, distance and link
    public static isSameRoute(Route r1, Route r2)
    {

        return r1.destination() == r2.destination() &&
               r1.gateway() == r2.gateway() && 
               r1.distance() == r2.distance() &&
               r1.link() == r2.link();
    }

    public bool opEquals(Route rhs)
    {
        return isSameRoute(this, rhs);
    }
}