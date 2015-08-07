#!/bin/sh

# # makedoc.sh
#
# This extracts embedded documentation from a file and builds
# a markdown document that interleves the documentation
# with the non-doc content as literal blocks.

parse_includes () {
	awk '
	$2 == "include:" {print $3}
	' $1
}

for src in $1 $(parse_includes $1); do
awk '
	/^#!/ {next}

	# Do not start generating output until we find our first
	# non-blank line (this prevents us from generating an
	# erroneous chunk of literal empty lines at the top of the
	# document).
	/^ *$/ && !found_first_line {next}
	!/^ *$/ {found_first_line=1}

	# Lines that begin with '#' are documentation.
	/^# ?/ {
		gsub(/^# ?/, "", $0)
		print
		last_was_doc=1
		next
	}

	# When we transition from documentation to code, we need to
	# generate an explicit break to prevent the code from becoming
	# part of a preceeding list.
	!/^# ?/ && last_was_doc==1 {
		printf "\n\n<!-- break -->\n\n"
		last_was_doc=0
	}

	# Everything else is code; print it indented four spaces.
	!/^# / {
		printf "    %s\n", $0
		last_was_doc=0
	}
' $src
done

