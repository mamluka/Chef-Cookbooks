require 'rubygems'
require 'sinatra'

set :port, 9494

post '/chef/upload' do
   system("/root/.chef/uploadme.sh")
end
