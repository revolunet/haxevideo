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

enum ArgSpecial<T> {
	ArgOpt( v : T );
}

class T {
	public static var Int = 0;
	public static var Float = 1.3;
	public static var String = "";
	public static var Bool = true;
	public static var Null : Void = null;
	public static var Object = new Hash<Value>();
	public static function Opt<T>(t : T) : T { return cast ArgOpt(t); }
}

class Commands<T> {

	static var VNull = [];

	var h : Hash<{ name : String, f : Dynamic, targs : Array<Dynamic> }>;

	public function new() {
		h = new Hash();
	}

	public function add0( name, f : T -> Void ) {
		h.set(name,{ name : name, f : f , targs : [] });
	}

	public function add1<A>( name, f : T -> A -> Void, a : A ) {
		h.set(name,{ name : name, f : f , targs : [a] });
	}

	public function add2<A,B>( name, f : T -> A -> B -> Void, a : A, b : B ) {
		h.set(name,{ name : name, f : f , targs : [a,b] });
	}

	public function add3<A,B,C>( name, f : T -> A -> B -> C -> Void, a : A, b : B, c : C ) {
		h.set(name,{ name : name, f : f , targs : [a,b,c] });
	}

	public function has( name ) {
		return h.exists(name);
	}

	function checkArg( a : Value, t : Dynamic ) {
		var v : Dynamic = null;
		switch( t ) {
		case T.Null:
			if( a == ANull || a == AUndefined )
				return VNull;
		case T.Int:
			v = format.amf.Tools.number(a);
			if( v != null ) {
				// sometimes, AMF sends floats that are not ints.
				// We will assume a .0001 precision here
				var i = Math.round(v);
				var e = v - i;
				if( e > 1e4 || e < -1e4 )
					v = null;
				else
					v = i;
			}
		case T.String: v = format.amf.Tools.string(a);
		case T.Float: v = format.amf.Tools.number(a);
		case T.Object: v = format.amf.Tools.object(a);
		case T.Bool: v = format.amf.Tools.bool(a);
		default:
			if( Std.is(t,ArgSpecial) ) {
				var tv = t;
				switch( tv ) {
				case ArgOpt(x):
					if( a == ANull || a == AUndefined )
						return VNull;
					return checkArg(a,x);
				}
			}
			throw "ASSERT : "+Std.string(t)+" "+Std.is(t,ArgSpecial);
		}
		return v;
	}

	function checkArgs( args : Array<Value>, targs : Array<Dynamic> ) {
		var ok = true;
		var vargs = new Array<Dynamic>();
		if( args.length > targs.length )
			return null;
		for( i in 0...args.length ) {
			var v = checkArg(args[i],targs[i]);
			if( v == null )
				return null;
			if( v == VNull )
				v = null;
			vargs.push(v);
		}
		// optional args
		for( i in args.length...targs.length ) {
			if( !Std.is(targs[i],ArgSpecial) )
				return null;
			vargs.push(null);
		}
		return vargs;
	}

	public function execute( cmd, infos : T, args ) {
		var c = h.get(cmd);
		if( c == null )
			return false;
		var vargs = checkArgs(args,c.targs);
		if( vargs == null )
			return false;
		neko.Lib.println(cmd.toUpperCase()+" "+vargs.join(", "));
		vargs.unshift(infos);
		Reflect.callMethod(null,c.f,vargs);
		return true;
	}

}