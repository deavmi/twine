module twine.core.linkman;

import twine.links.link;
import std.container.slist : SList;
import core.sync.mutex : Mutex;

public class LinkManager
{
    private SList!(Link) links;
    private Mutex linksLock;

    private Receiver receiver; // make const

    this(Receiver receiver)
    {
        this.receiver = receiver;
        this.linksLock = new Mutex();
    }

    public final void addLink(Link link)
    {
        this.linksLock.lock();

        scope(exit)
        {
            this.linksLock.unlock();
        }

        // Add link
        this.links.insertAfter(this.links[], link);

        // Set its receiver
        link.attachReceiver(this.receiver);
    }

    public final Link[] getLinks()
    {
        this.linksLock.lock();

        scope(exit)
        {
            this.linksLock.unlock();
        }

        Link[] cpy;
        foreach(Link link; this.links)
        {
            cpy ~= link;
        }

        return cpy;
    }
}

