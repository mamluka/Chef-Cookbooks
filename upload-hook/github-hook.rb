require 'rubygems'
require 'sinatra'

set :port, 9494

post '/chef/upload' do
   puts `/root/.chef/chef-repo/uploadme.sh`
end
