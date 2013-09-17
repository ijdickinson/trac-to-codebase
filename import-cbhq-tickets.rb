#!/usr/bin/env ruby
#
# Quick-and-dirty script to upload tickets from a Trac instance to the trackers
# available in CodebaseHQ, using their API.
#
# Process: export the Trac tickets as a CSV. Suppose the project that we're going
# to write to in CodebaseHQ is 'foo', then either:
#
# ruby import-cbhq-tickets.rb -d foo-trac.csv foo    # dry-run only
# ruby import-cbhq-tickets.rb -a foo-trac.csv foo    # actual update
#
# Script assumes that your CodebaseHQ user-ID and API token are in the
# environment variables CODEBASE_USER and CODEBASE_API_TOKEN respectively.
#
# For details on the codebaseHQ API, see: http://support.codebasehq.com/kb
#
# Dependencies:
# gem install multi_xml faraday_middleware nokogiri

require 'logger'
require 'faraday_middleware'
require 'multi_xml'
require 'nokogiri'
require 'csv'

raise "Usage: ruby import-cbhq-tickets.rb (-d | -a) <file> <project-name>" unless ARGV.length == 3
raise "Usage: ruby import-cbhq-tickets.rb (-d | -a) <file> <project-name>" unless ["-a", "-d"].include?( ARGV[0] )

$user=ENV['CODEBASE_USER']
$token=ENV['CODEBASE_API_TOKEN']

# Return true if this is just a dry run, doesn't make any changes
def dry_run?
  ARGV[0] == "-d"
end

# Return the input file, or raise an error
def input_file
  f = ARGV[1]
  raise "No such file: #{f}" unless File.exist?( f )
  f
end

# Return the project name that we're updating
def project_name
  ARGV[2]
end

# Create a connection to CodebaseHQ's API
conn = Faraday.new 'https://api3.codebasehq.com/', ssl: {verify: false} do |c|
  c.use Faraday::Response::Logger,          Logger.new('faraday.log')
  c.use FaradayMiddleware::FollowRedirects, limit: 3
  c.use Faraday::Response::RaiseError       # raise exceptions on 40x, 50x responses
  c.use Faraday::Adapter::NetHttp
  c.response :xml,  :content_type => /\bxml$/
end

conn.headers[:user_agent] = 'Ruby script'
conn.basic_auth($user, $token)

# Download some info about the project, so that we can do the mappings
$statuses = conn.get( "/#{project_name}/tickets/statuses" ).body
$priorities = conn.get( "/#{project_name}/tickets/priorities" ).body
$categories = conn.get( "/#{project_name}/tickets/categories" ).body
$assigned_users = conn.get( "/#{project_name}/assignments" ).body
$milestones = conn.get( "/#{project_name}/milestones" ).body

if dry_run?
  puts "This is what we got back from codebaseHQ:"
  puts "Status: #{$statuses.inspect}"
  puts "Priority: #{$priorities.inspect}"
  puts "Category: #{$categories.inspect}"
  puts "Milesone: #{$milestones.inspect}"
end

$ticket_type_translations = {
  "defect" => "bug",
  "enhancement" => "enhancement",
  "task" => "task"
}

$priority_translations = {
  "critical" => "Critical",
  "major" => "High",
  "minor" => "Normal",
  "trivial" => "Low",
  "irritating" => "Normal"
}

$status_translations = {
  "closed" => "Completed",
  "accepted" => "Accepted",
  "new" => "New",
  "assigned" => "Accepted",
  "reopened" => "In Progress"
}

# return the user id for a given user
def user_id_for_email( email )
  u = $assigned_users["users"].find {|user| user["email_address"] == email}
  raise "Unknown user email #{email}" unless u
  u["id"]
end

def find_id_by_name( list, prompt, name, translation_table = nil )
  if translation_table
    n = name
    name = translation_table[name]
    raise "No translation for #{prompt} #{n}" unless name
  end

  c = list.find {|item| item["name"] == name }
  raise "Unknown #{prompt} #{name}" unless c
  c["id"]
end

# Build an XML structure to represent the ticket for codebase, using
# info from a row of the CSV of Trac data
def new_ticket_structure( row )
  builder = Nokogiri::XML::Builder.new( encoding: "UTF-8" ) do |xml|
    xml.ticket do
      xml.summary {xml.cdata row["summary"]}
      xml.description {xml.cdata row["description"]} if row["description"]
      xml.send( :'ticket-type', $ticket_type_translations[ row["type"] ])
      xml.send( :'reporter-id', user_id_for_email( row["reporter"] ))
      xml.send( :'assignee-id', user_id_for_email( row["owner"] ))
      xml.send( :'category-id', find_id_by_name( $categories["ticketing_categories"], "category", row["component"] ))
      xml.send( :'priority-id', find_id_by_name( $priorities["ticketing_priorities"], "priority", row["priority"], $priority_translations ))
      xml.send( :'status-id', find_id_by_name( $statuses["ticketing_statuses"], "status", row["status"], $status_translations ))
      if row["milestone"]
        xml.send( :'milestone-id', find_id_by_name( $milestones["ticketing_milestone"], "milestone", row["milestone"] ))
      end
    end
  end

  builder.to_xml
end

# and here we start processing the CSV of exported Trac data
csv = CSV.open( input_file, {headers: true, encoding: "UTF-8"} )

csv.each_with_index do |row,n|
  payload = new_ticket_structure( row )
  begin
    if dry_run?
      puts payload.inspect
    else
      conn.post do |req|
        req.url "/#{project_name}/tickets"
        req.headers['Content-Type'] = 'application/xml'
        req.body = payload
      end
    end
  rescue
    puts "Failed update on row #{n}"
    puts "#{payload}\n-----------------"
  end
end
