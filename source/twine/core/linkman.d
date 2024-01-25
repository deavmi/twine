module twine.core.linkman;

import twine.links.link;
import std.container.slist : SList;
import core.sync.mutex : Mutex;

/** 
 * Manages links in a manner that
 * a single `Receiver` can be responsible
 * for all such links attached or
 * to be attached in the future
 */
public class LinkManager
{
    private SList!(Link) links;
    private Mutex linksLock;

    private Receiver receiver; // make const

    /** 
     * Constructs a new `LinkManager`
     * with the given receiver
     *
     * Params:
     *   receiver = the receiver
     * to use
     */
    this(Receiver receiver)
    {
        this.receiver = receiver;
        this.linksLock = new Mutex();
    }

    /** 
     * Adds this link such that we will
     * receive data packets from it onto
     * our `Receiver`
     *
     * Params:
     *   link = the link to add
     */
    public final void addLink(Link link)
    {
        this.linksLock.lock();

        scope(exit)
        {
            this.linksLock.unlock();
        }

        // Add link
        this.links.insertAfter(this.links[], link);

        // Receive data from this link
        link.attachReceiver(this.receiver);
    }

    /** 
     * Removes this link and ensures
     * we no longer receive data
     * packets from it to our
     * `Receiver`
     *
     * Params:
     *   link = the link to remove
     */
    public final void removeLink(Link link)
    {
        this.linksLock.lock();

        scope(exit)
        {
            this.linksLock.unlock();
        }

        // Remove the link
        this.links.linearRemoveElement(link);

        // Don't receive data from this link anymore
        link.removeReceiver(this.receiver);
    }

    /** 
     * Get a list of all attached links
     *
     * Returns: an array
     */
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