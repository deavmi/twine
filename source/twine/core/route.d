module twine.core.route;

import twine.links.link;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.datetime : Duration, dur;

public struct Route
{
    private string dstKey; // destination
    private Link ll; // link to use
    private string viaKey; // gateway (can be empty)
    private ubyte dst;

    private StopWatch lifetime;
    private Duration expirationTime;

    // direct route (reachable over the given link)
    this(string dst, Link link, ubyte distance)
    {
        this(dst, link, dst, distance);
    }

    // indirect route (reachable via the `via`)
    this(string dst, Link link, string via, ubyte distance, Duration expirationTime = dur!("seconds")(60))
    {
        this.dstKey = dst;
        this.ll = link;
        this.viaKey = via;
        this.dst = distance;

        this.lifetime = StopWatch(AutoStart.yes);
        this.expirationTime = expirationTime;
    }

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
}