deploy:
	rsync --delete --exclude=.svn -zav www ncannasse@haxevideo.org:./