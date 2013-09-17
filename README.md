# Trac to codebase


Quick-and-dirty Ruby script for importing Trac tickets saved as CSV's into CodebaseHQ tracker items. Uses the 
codebaseHQ API to first look up the target project's details (e.g. the set of known users), then formulates
the XML payload representing the new ticket and submits that over the API.

Run first in dry-run mode, `-d`, to see if the fields from the Trac export CSV can be mapped to the ticket 
details from codebase.
