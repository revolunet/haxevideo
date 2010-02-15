/* ************************************************************************ */
/*																			*/
/*  haXe Video 																*/
/*  Copyright (c)2007 Nicolas Cannasse										*/
/*  SharedObject contributed by Russell Weir								*/
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

enum SOCommand {
	SOConnect;
	SODisconnect;
	SOSetAttribute( name : String, value : Value );
	SOUpdateData( data : Hash<Value> );
	SOUpdateAttribute( name : String );
	SOSendMessage( msg : Value );
	SOStatus( msg : String, type : String );
	SOClearData;
	SODeleteData;
	SODeleteAttribute( name : String );
	SOInitialData;
}

typedef SOData = {
	var name : String;
	var version : Int;
	var persist : Bool;
	var unknown : Int;
	var commands : List<SOCommand>;
}

class SharedObject {

	inline static function readString( i : haxe.io.Input ) {
		return i.readString(i.readUInt16());
	}

	public static function read( i : haxe.io.Input, r : format.amf.Reader ) : SOData {
		var name = readString(i);
		var ver = i.readUInt30();
		var persist = i.readUInt30() == 2;
		var unk = i.readUInt30();
		var cmds = new List();
		while( true ) {
			var c = try i.readByte() catch( e : haxe.io.Eof ) break;
			var size = i.readUInt30();
			var cmd = switch( c ) {
			case 1:
				SOConnect;
			case 2:
				SODisconnect;
			case 3:
				var name = readString(i);
				SOSetAttribute(name,r.read());
			case 4:
				var values = new haxe.io.BytesInput(i.read(size));
				var r = new format.amf.Reader(values);
				var hash = new Hash();
				while( true ) {
					var size = try values.readUInt16() catch( e : haxe.io.Eof ) break;
					var name = values.readString(size);
					hash.set(name,r.read());
				}
				SOUpdateData(hash);
			case 5:
				SOUpdateAttribute(readString(i));
			case 6:
				SOSendMessage(r.read());
			case 7:
				var msg = readString(i);
				var type = readString(i);
				SOStatus(msg,type);
			case 8:
				SOClearData;
			case 9:
				SODeleteData;
			case 10:
				SODeleteAttribute(readString(i));
			case 11:
				SOInitialData;
			}
		}
		return {
			name : name,
			version : ver,
			persist : persist,
			unknown : unk,
			commands : cmds,
		};
	}

	static function writeString( o : haxe.io.Output, s : String ) {
		o.writeUInt16(s.length);
		o.writeString(s);
	}

	static function writeCommandData( o : haxe.io.Output, w : format.amf.Writer, cmd ) {
		switch( cmd ) {
		case SOConnect,SODisconnect,SOClearData,SODeleteData,SOInitialData:
			// nothing
		case SOSetAttribute(name,value):
			writeString(o,name);
			w.write(value);
		case SOUpdateData(data):
			for( k in data.keys() ) {
				writeString(o,k);
				w.write(data.get(k));
			}
		case SOUpdateAttribute(name):
			writeString(o,name);
		case SOSendMessage(msg):
			w.write(msg);
		case SOStatus(msg,type):
			writeString(o,msg);
			writeString(o,type);
		case SODeleteAttribute(name):
			writeString(o,name);
		}
	}

	public static function write( o : haxe.io.Output, so : SOData ) {
		o.writeUInt16(so.name.length);
		o.writeString(so.name);
		o.writeUInt30(so.version);
		o.writeUInt30(so.persist?2:0);
		o.writeUInt30(so.unknown);
		for( cmd in so.commands ) {
			o.writeByte( Type.enumIndex(cmd) + 1 );
			var s = new haxe.io.BytesOutput();
			var w = new format.amf.Writer(s);
			writeCommandData(s,w,cmd);
			var data = s.getBytes();
			o.writeUInt30(data.length);
			o.write(data);
		}
	}

}
