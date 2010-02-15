/* ************************************************************************ */
/*																			*/
/*  haXe Video 																*/
/*  Copyright (c)2007 Nicolas Cannasse										*/
/*																			*/
/* This library is free software; you can redistribute it and/or			*/
/* modify it under the terms of the GNU Lesser General Public				*/
/* License as published by the Free Software Foundation; either				*/
/* version 2.1 of the License, or (at your option) any later version.		*/
/*																			*/
/* This library is distributed in the hope that it will be useful,			*/
/* but WITHOUT ANY WARRANTY; without even the implied warranty of			*/
/* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU		*/
/* Lesser General Public License or the LICENSE file for more details.		*/
/*																			*/
/* ************************************************************************ */
package hxvid;
import neko.net.Socket;

private typedef ThreadInfos = {
	var t : neko.vm.Thread;
	var socks : Array<neko.net.Socket>;
	var wsocks : Array<neko.net.Socket>;
	var sleeps : Array<{ s : neko.net.Socket, time : Float }>;
}

private typedef SocketInfos<Client> = {
	var sock : neko.net.Socket;
	var handle : SocketHandle;
	var client : Client;
	var thread : ThreadInfos;
	var wbuffer : haxe.io.Bytes;
	var wbytes : Int;
	var rbuffer : haxe.io.Bytes;
	var rbytes : Int;
}

private enum ThreadMessage {
	Connect( s : Socket );
	Disconnect( s : Socket );
	Wakeup( s : Socket, delay : Float );
}

class RealtimeSocketOutput<Client> extends neko.net.SocketOutput {

	var c : SocketInfos<Client>;

	public function new(c) {
		this.c = c;
		super(c.handle);
	}

	override function writeByte( ch : Int ) {
		if( c.wbytes == 0 )
			c.thread.wsocks.push(c.sock);
		c.wbuffer.set(c.wbytes,ch);
		c.wbytes += 1;
	}

	override function writeBytes( buf : haxe.io.Bytes, pos : Int, len : Int ) {
		if( len == 0 )
			return 0;
		if( c.wbytes == 0 )
			c.thread.wsocks.push(c.sock);
		c.wbuffer.blit(c.wbytes,buf,pos,len);
		c.wbytes += len;
		return len;
	}
}

class RealtimeServer<Client> {

	public var config : {
		listenValue : Int,
		connectLag : Float,
		minReadBufferSize : Int,
		maxReadBufferSize : Int,
		writeBufferSize : Int,
		blockingBytes : Int,
		messageHeaderSize : Int,
		threadsCount : Int,
	};
	var sock : neko.net.Socket;
	var threads : Array<ThreadInfos>;

	private static var socket_send_char : SocketHandle -> Int -> Void = neko.Lib.load("std","socket_send_char",2);
	private static var socket_send : SocketHandle -> Dynamic -> Int -> Int -> Int = neko.Lib.load("std","socket_send",4);

	public function new() {
		threads = new Array();
		config = {
			listenValue : 10,
			connectLag : 0.05,
			minReadBufferSize : 1 << 10, // 1 KB
			maxReadBufferSize : 1 << 16, // 64 KB
			writeBufferSize : 1 << 18, // 256 KB
			blockingBytes : 1 << 17, // 128 KB
			messageHeaderSize : 1,
			threadsCount : 10,
		};
	}

	public function run( host : String, port : Int ) {
		var h = new neko.net.Host(host);
		sock = new neko.net.Socket();
		sock.bind(h,port);
		sock.listen(config.listenValue);
		while( true ) {
			var s = sock.accept();
			s.setBlocking(false);
			addClient(s);
		}
	}

	function logError( e : Dynamic ) {
		var stack = haxe.Stack.exceptionStack();
		var str = "["+Date.now().toString()+"] "+(try Std.string(e) catch( e : Dynamic ) "???");
		neko.Lib.print(str+"\n"+haxe.Stack.toString(stack));
	}

	function cleanup( t : ThreadInfos, s : neko.net.Socket ) {
		if( !t.socks.remove(s) )
			return;
		try s.close() catch( e : Dynamic ) { };
		t.wsocks.remove(s);
		var i = 0;
		while( i < t.sleeps.length )
			if( t.sleeps[i].s == s )
				t.sleeps.splice(i,1);
			else
				i++;
		try {
			clientDisconnected(getInfos(s).client);
		} catch( e : Dynamic ) {
			logError(e);
		}
	}

	function readWriteThread( t : ThreadInfos ) {
		var socks = neko.net.Socket.select(t.socks,t.wsocks,null,config.connectLag);
		for( s in socks.read ) {
			var ok = try clientRead(getInfos(s)) catch( e : Dynamic ) { logError(e); false; };
			if( !ok ) {
				socks.write.remove(s);
				cleanup(t,s);
			}
		}
		for( s in socks.write ) {
			var ok = try clientWrite(getInfos(s)) catch( e : Dynamic ) { logError(e); false; };
			if( !ok )
				cleanup(t,s);
		}
	}

	function loopThread( t : ThreadInfos ) {
		var now = neko.Sys.time();
		var i = 0;
		while( i < t.sleeps.length ) {
			var s = t.sleeps[i];
			if( s.time <= now ) {
				t.sleeps.splice(i,1);
				clientWakeUp(getInfos(s.s).client);
			} else
				i++;
		}
		if( t.socks.length > 0 )
			readWriteThread(t);
		while( true ) {
			var m : ThreadMessage = neko.vm.Thread.readMessage(t.socks.length == 0);
			if( m == null ) break;
			switch( m ) {
			case Connect(s):
				t.socks.push(s);
				var inf = getInfos(s);
				inf.client = clientConnected(s);
				if( t.socks.length >= 64 ) {
					logError("Max clients per thread reached");
					cleanup(t,s);
				}
			case Disconnect(s):
				cleanup(t,s);
			case Wakeup(s,time):
				var sl = t.sleeps;
				var push = true;
				for( i in 0...sl.length )
					if( sl[i].time > time ) {
						sl.insert(i,{ s : s, time : time });
						push = false;
						break;
					}
				if( push )
					sl.push({ s : s, time : time });
			}
		}
	}

	function runThread( t ) {
		while( true )
			try loopThread(t) catch( e : Dynamic ) logError(e);
	}

	function initThread() {
		var t : ThreadInfos = {
			t : null,
			socks : new Array(),
			wsocks : new Array(),
			sleeps : new Array(),
		};
		t.t = neko.vm.Thread.create(callback(runThread,t));
		return t;
	}

	function addClient( s : neko.net.Socket ) {
		var tid = Std.random(config.threadsCount);
		var thread = threads[tid];
		if( thread == null ) {
			thread = initThread();
			threads[tid] = thread;
		}
		var sh : { private var __s : SocketHandle; } = s;
		var cinf : SocketInfos<Client> = {
			sock : s,
			handle : sh.__s,
			client : null,
			thread : thread,
			wbuffer : haxe.io.Bytes.alloc(config.writeBufferSize),
			wbytes : 0,
			rbuffer : haxe.io.Bytes.alloc(config.minReadBufferSize),
			rbytes : 0,
		};
		untyped s.output = new RealtimeSocketOutput(cinf);
		s.custom = cinf;
		cinf.thread.t.sendMessage(Connect(s));
	}

	function getInfos( s : neko.net.Socket ) : SocketInfos<Client> {
		return s.custom;
	}

	function clientWrite( c : SocketInfos<Client> ) {
		var pos = 0;
		while( c.wbytes > 0 )
			try {
				var len = socket_send(c.handle,c.wbuffer.getData(),pos,c.wbytes);
				pos += len;
				c.wbytes -= len;
			} catch( e : Dynamic ) {
				if( e != "Blocking" )
					return false;
				break;
			}
		if( c.wbytes == 0 ) {
			c.thread.wsocks.remove(c.sock);
			clientFillBuffer(c.client);
		} else
			c.wbuffer.blit(0,c.wbuffer,pos,c.wbytes);
		return true;
	}

	function clientRead( c : SocketInfos<Client> ) {
		var available = c.rbuffer.length - c.rbytes;
		if( available == 0 ) {
			var newsize = c.rbuffer.length * 2;
			if( newsize > config.maxReadBufferSize ) {
				newsize = config.maxReadBufferSize;
				if( c.rbuffer.length == config.maxReadBufferSize )
					throw "Max buffer size reached";
			}
			var newbuf = haxe.io.Bytes.alloc(newsize);
			newbuf.blit(0,c.rbuffer,0,c.rbytes);
			c.rbuffer = newbuf;
			available = newsize - c.rbytes;
		}
		try {
			c.rbytes += c.sock.input.readBytes(c.rbuffer,c.rbytes,available);
		} catch( e : Dynamic ) {
			if( !Std.is(e,haxe.io.Eof) && !Std.is(e,haxe.io.Error) )
				neko.Lib.rethrow(e);
			return false;
		}
		var pos = 0;
		while( c.rbytes >= config.messageHeaderSize ) {
			var m = readClientMessage(c.client,c.rbuffer,pos,c.rbytes);
			if( m == null )
				break;
			pos += m;
			c.rbytes -= m;
		}
		if( pos > 0 )
			c.rbuffer.blit(0,c.rbuffer,pos,c.rbytes);
		return true;
	}

	// ---------- API ----------------

	public function clientConnected( s : neko.net.Socket ) : Client {
		return null;
	}

	public function readClientMessage( c : Client, buf : haxe.io.Bytes, pos : Int, len : Int ) : Int {
		return null;
	}

	public function clientDisconnected( c : Client ) {
	}

	public function clientFillBuffer( c : Client ) {
	}

	public function clientWakeUp( c : Client ) {
	}

	public function isBlocking( s : neko.net.Socket ) {
		return getInfos(s).wbytes > config.blockingBytes;
	}

	public function wakeUp( s : neko.net.Socket, delay : Float ) {
		var inf = getInfos(s);
		inf.thread.t.sendMessage(Wakeup(s,neko.Sys.time() + delay));
	}

	public function stopClient( s : neko.net.Socket ) {
		var inf = getInfos(s);
		try s.shutdown(true,true) catch( e : Dynamic ) { };
		inf.thread.t.sendMessage(Disconnect(s));
	}

}