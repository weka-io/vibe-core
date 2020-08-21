import vibe.core.core : runApplication;
import vibe.core.log;
import vibe.core.net : listenTCP;
import vibe.core.stream : pipe;

void main()
{
	listenTCP(7000, (conn) @safe nothrow {
			try pipe(conn, conn);
			catch (Exception e)
				logError("Error: %s", e.msg);
	});
	runApplication();
}
