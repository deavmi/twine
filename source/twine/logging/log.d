module twine.logging.log;

import gogga;

public __gshared static GoggaLogger logger;

__gshared static this()
{
    logger = new GoggaLogger(); // todo, set multi-arg joiner to `""` (i don't like the default `" "`)
    logger.enableDebug();
    logger.mode(GoggaMode.RUSTACEAN_SIMPLE);
}