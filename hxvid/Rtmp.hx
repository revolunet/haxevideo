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
import format.amf.Value;
import hxvid.SharedObject;

enum RtmpKind {
	KCall;
	KVideo;
	KAudio;
	KMeta;
	KChunkSize;
	KBytesReaded;
	KCommand;
	KShared;
	KUnknown( v : Int );
}

enum RtmpCommand {
	CClear;
	CPlay;
	CReset;
	CPing( v : Int );
	CPong( v : Int );
	CClientBuffer( v : Int );
	CUnknown( kind : Int, ?v1 : Int, ?v2 : Int );
}

enum RtmpPacket {
	PCall( name : String, iid : Int, args : Array<Value> );
	PVideo( data : haxe.io.Bytes );
	PAudio( data : haxe.io.Bytes );
	PMeta( data : haxe.io.Bytes );
	PCommand( sid : Int, v : RtmpCommand );
	PBytesReaded( nbytes : Int );
	PShared( data : SOData );
	PUnknown( kind : Int, body : haxe.io.Bytes );
}

typedef RtmpHeader = {
	var channel : Int;
	var timestamp : Int;
	var kind : RtmpKind;
	var src_dst : Int;
	var size : Int;
}

class Rtmp {

	public static var HANDSHAKE_SIZE = 0x600;

	static var HEADER_SIZES = [12,8,4,1];
	static var INV_HSIZES = [null,3,null,null,2,null,null,null,1,null,null,null,0];
	static var COMMAND_SIZES = [0,0,null,4,0,4,4];

	static function kindToInt(k) {
		return switch(k) {
		case KChunkSize: 0x01;
		case KBytesReaded: 0x03;
		case KCommand: 0x04;
		case KAudio: 0x08;
		case KVideo: 0x09;
		case KMeta: 0x12;
		case KShared: 0x13;
		case KCall: 0x14;
		case KUnknown(b): b;
		}
	}

	static function kindOfInt(n) {
		var k = HKINDS[n];
		if( k == null )
			return KUnknown(n);
		return k;
	}

	static var HKINDS = {
		var a = new Array<RtmpKind>();
		for( kname in Type.getEnumConstructs(cast RtmpKind) ) {
			if( kname == "KUnknown" )
				continue;
			var k = Reflect.field(RtmpKind,kname);
			a[kindToInt(k)] = k;
		}
		a;
	};

	var channels : Array<{ header : RtmpHeader, buffer : haxe.io.BytesBuffer, bytes : Int }>;
	var saves : Array<RtmpHeader>;
	var read_chunk_size : Int;
	var write_chunk_size : Int;
	public var i : haxe.io.Input;
	public var o : haxe.io.Output;

	public function new(input,output) {
		i = input;
		o = output;
		read_chunk_size = 128;
		write_chunk_size = 128;
		channels = new Array();
		saves = new Array();
	}

	public function readWelcome() {
		if( i.readByte() != 3 )
			throw "Invalid Welcome";
	}

	public function readHandshake() {
		var uptimeLow = i.readUInt16();
		var uptimeHigh = i.readUInt16();
		var ping = i.readInt32();
		return i.read(HANDSHAKE_SIZE - 8);
	}

	public function writeWelcome() {
		o.writeByte(3);
	}

	public function writeHandshake( hs ) {
		o.writeUInt30(1); // uptime
		o.writeUInt30(1); // ping
		o.write(hs);
	}

	public function getHeaderSize( h : Int ) {
		var ch = h & 63;
		return HEADER_SIZES[h >> 6] + ((ch > 1) ? 0 : (ch == 0) ? 1 : 2);
	}

	function getLastHeader( channel ) {
		var h = saves[channel];
		if( h == null ) {
			h = {
				channel : channel,
				timestamp : null,
				size : null,
				kind : null,
				src_dst : null,
			};
			saves[channel] = h;
		}
		return h;
	}

	public function readHeader() : RtmpHeader {
		var h = i.readByte();
		var hsize = HEADER_SIZES[h >> 6];
		var channel = h & 63;
		if( channel == 0 )
			channel = i.readByte() + 64;
		else if( channel == 1 ) {
			var c0 = i.readByte();
			channel = (c0 | (i.readByte() << 8)) + 64;
		}
		var last = getLastHeader(channel);
		if( hsize >= 4 ) last.timestamp = i.readUInt24();
		if( hsize >= 8 ) last.size = i.readUInt24();
		if( hsize >= 8 ) last.kind = kindOfInt(i.readByte());
		if( hsize == 12 ) {
			i.bigEndian = false;
			last.src_dst = i.readInt31();
			i.bigEndian = true;
		}
		return {
			channel : channel,
			timestamp : last.timestamp,
			kind : last.kind,
			src_dst : last.src_dst,
			size : last.size,
		};
	}

	function writeChannel( ch : Int, hsize : Int ) {
		if( ch <= 63 )
			o.writeByte(ch | (INV_HSIZES[hsize] << 6));
		else if( ch < 320 ) {
			o.writeByte(INV_HSIZES[hsize] << 6);
			o.writeByte(ch - 64);
		} else {
			o.writeByte((INV_HSIZES[hsize] << 6) | 1);
			ch -= 64;
			o.writeByte(ch & 0xFF);
			o.writeByte(ch >> 8);
		}
	}

	function writeHeader( p : RtmpHeader ) {
		var hsize;
		if( p.src_dst != null )
			hsize = 12;
		else if( p.kind != null )
			hsize = 8;
		else if( p.timestamp != null )
			hsize = 4;
		else
			hsize = 1;
		writeChannel(p.channel,hsize);
		if( hsize >= 4 )
			o.writeUInt24(p.timestamp);
		if( hsize >= 8 ) {
			o.writeUInt24(p.size);
			o.writeByte(kindToInt(p.kind));
		}
		if( hsize == 12 ) {
			o.bigEndian = false;
			o.writeInt31(p.src_dst);
			o.bigEndian = true;
		}
	}

	public function send( channel : Int, p : RtmpPacket, ?ts, ?streamid ) {
		var h = {
			channel : channel,
			timestamp : if( ts != null ) ts else 0,
			kind : null,
			src_dst : if( streamid != null ) streamid else 0,
			size : null
		};
		var data = null;
		switch( p ) {
		case PCommand(sid,cmd):
			var o = new haxe.io.BytesOutput();
			o.bigEndian = true;
			var kind,v1 = null,v2 = null;
			switch( cmd ) {
			case CClear:
				kind = 0;
			case CPlay:
				kind = 1;
			case CClientBuffer(v):
				kind = 3;
				v1 = v;
			case CReset:
				kind = 4;
			case CPing(v):
				kind = 6;
				v1 = v;
			case CPong(v):
				kind = 7;
				v1 = v;
			case CUnknown(k,a,b):
				kind = k;
				v1 = a;
				v2 = b;
			}
			o.writeUInt16(kind);
			o.writeUInt30(sid);
			if( v1 != null )
				o.writeUInt30(v1);
			if( v2 != null )
				o.writeUInt30(v2);
			data = o.getBytes();
			h.kind = KCommand;
		case PCall(cmd,iid,args):
			var o = new haxe.io.BytesOutput();
			var w = new format.amf.Writer(o);
			w.write(AString(cmd));
			w.write(ANumber(iid));
			for( x in args )
				w.write(x);
			data = o.getBytes();
			h.kind = KCall;
		case PAudio(d):
			data = d;
			h.kind = KAudio;
		case PVideo(d):
			data = d;
			h.kind = KVideo;
		case PMeta(d):
			data = d;
			h.kind = KMeta;
		case PBytesReaded(n):
			var s = new haxe.io.BytesOutput();
			s.bigEndian = true;
			s.writeUInt30(n);
			data = s.getBytes();
			h.kind = KBytesReaded;
		case PShared(so):
			var s = new haxe.io.BytesOutput();
			s.bigEndian = true;
			SharedObject.write(s,so);
			data = s.getBytes();
			h.kind = KShared;
		case PUnknown(k,d):
			data = d;
			h.kind = KUnknown(k);
		}
		h.size = data.length;
		// write packet header + data
		writeHeader(h);
		var pos = write_chunk_size;
		if( data.length <= pos )
			o.write(data);
		else {
			var len = data.length - pos;
			o.writeFullBytes(data,0,pos);
			while( len > 0 ) {
				writeChannel(channel,1);
				var n = if( len > write_chunk_size ) write_chunk_size else len;
				o.writeFullBytes(data,pos,n);
				pos += n;
				len -= n;
			}
		}
	}

	function processBody( h : RtmpHeader, body : haxe.io.Bytes ) {
		switch( h.kind ) {
		case KCall:
			var i = new haxe.io.BytesInput(body);
			var r = new format.amf.Reader(i);
			var name = switch( r.read() ) { case AString(s): s; default: throw "Invalid name"; }
			var iid = switch( r.read() ) { case ANumber(n): Std.int(n); default: throw "Invalid nargs"; }
			var args = new Array();
			while( true ) {
				var c = try i.readByte() catch( e : Dynamic ) break;
				args.push(r.readWithCode(c));
			}
			return PCall(name,iid,args);
		case KVideo:
			return PVideo(body);
		case KAudio:
			return PAudio(body);
		case KMeta:
			return PMeta(body);
		case KCommand:
			var i = new haxe.io.BytesInput(body);
			i.bigEndian = true;
			var kind = i.readUInt16();
			var sid = i.readUInt30();
			var bsize = COMMAND_SIZES[kind];
			if( bsize != null && body.length != bsize + 6 )
				throw "Invalid command size ("+kind+","+body.length+")";
			var cmd = switch( kind ) {
			case 0:
				CClear;
			case 1:
				CPlay;
			case 3:
				CClientBuffer( i.readUInt30() );
			case 4:
				CReset;
			case 6:
				CPing( i.readUInt30() );
			default:
				if( body.length != 6 && body.length != 10 && body.length != 14 )
					throw "Invalid command size ("+kind+","+body.length+")";
				var a = if( body.length > 6 ) i.readUInt30() else null;
				var b = if( body.length > 10 ) i.readUInt30() else null;
				CUnknown(kind,a,b);
			};
			return PCommand(sid,cmd);
		case KShared:
			var i = new haxe.io.BytesInput(body);
			var so = SharedObject.read(i,new format.amf.Reader(i));
			return PShared(so);
		case KUnknown(k):
			return PUnknown(k,body);
		case KChunkSize:
			var i = new haxe.io.BytesInput(body);
			i.bigEndian = true;
			read_chunk_size = i.readUInt30();
			return null;
		case KBytesReaded:
			var i = new haxe.io.BytesInput(body);
			i.bigEndian = true;
			return PBytesReaded(i.readUInt30());
		}
	}

	public function bodyLength( h : RtmpHeader, read : Bool ) {
		var chunk_size = if( read ) read_chunk_size else write_chunk_size;
		var s = channels[h.channel];
		if( s == null ) {
			if( h.size < chunk_size )
				return h.size;
			return chunk_size;
		} else {
			if( s.bytes < chunk_size )
				return s.bytes;
			return chunk_size;
		}
	}

	public function readPacket( h : RtmpHeader ) {
		var s = channels[h.channel];
		if( s == null ) {
			if( h.size <= read_chunk_size )
				return processBody(h,i.read(h.size));
			var buf = new haxe.io.BytesBuffer();
			buf.add(i.read(read_chunk_size));
			channels[h.channel] = { header : h, buffer : buf, bytes : h.size - read_chunk_size };
		} else {
			if( h.timestamp != s.header.timestamp )
				throw "Timestamp changing";
			if( h.src_dst != s.header.src_dst )
				throw "Src/dst changing";
			if( h.kind != s.header.kind )
				throw "Kind changing";
			if( h.size != s.header.size )
				throw "Size changing";
			if( s.bytes > read_chunk_size ) {
				s.buffer.add(i.read(read_chunk_size));
				s.bytes -= read_chunk_size;
			} else {
				s.buffer.add(i.read(s.bytes));
				channels[h.channel] = null;
				return processBody(s.header,s.buffer.getBytes());
			}
		}
		return null;
	}

	public function close() {
		if( i != null )
			i.close();
		if( o != null )
			o.close();
	}

}
