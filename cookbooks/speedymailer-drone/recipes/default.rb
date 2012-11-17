# Cookbook Name:: speedymailer-drone
# Recipe:: default
#
# Copyright 2012, YOUR_COMPANY_NAME
#
# All rights reserved - Do Not Redistribute
#
include_recipe "apt"
include_recipe "git"
include_recipe "ruby::1.9.1"
include_recipe "rubygems"

package 'libgvc5'
package 'libgraphviz-dev'
package 'libmagickcore-dev'
package 'libmagickcore4-extra'
package 'libmagickwand-dev'
package 'libxslt-dev'
package 'libxml2-dev'
package 'mailutils'
package 'curl'
package 'mongodb'

#write ip and domain

e = execute "apt-get update" do
  action :nothing
end
 
e.run_action(:run)

dns_utils = package "dnsutils" do
  action :nothing
end

dns_utils.run_action(:install)

node.default["drone"]["ip"] = `/usr/bin/wget -q -O- http://ipecho.net/plain`
node.default["drone"]["domain"] = `/usr/bin/dig +noall +answer -x #{node.default["drone"]["ip"]} | awk '{$5=substr($5,1,length($5)-1); print $5}' | tr  -d '\n'`

#install mono

apt_repository "mono-rep" do
  uri "http://ppa.launchpad.net/borgdylan/ppa/ubuntu"
  distribution node['lsb']['codename']
  components ["main"]
  keyserver "keyserver.ubuntu.com"
  key "4B47C289FADDF7CF01380548FAAB7362B99C283A"
  deb_src true
end

apt_repository "rsyslog" do
  uri "http://ppa.launchpad.net/ukplc-team/testing/ubuntu"
  distribution node['lsb']['codename']
  components ["main"]
  keyserver "keyserver.ubuntu.com"
  key "F262AA585E04325397D7C8BA1C7DAF1E1A39EA92"
  deb_src true
end

package 'rsyslog'
package 'rsyslog-mongodb'
package 'mono-runtime'
package 'mono-devel'

#set host to be a mail server

file "/etc/hostname" do
     content "mail"
end

#setup rsyslog logging to mongo

template "/etc/rsyslog.d/10-mongodb.conf" do
    source "10-mongodb.conf.erb"
    mode 0664
    owner "root"
    group "root"
end


#set the domain in the hosts file
script "add-domain-to-hosts-file" do
    interpreter "bash"
    user "root"
    cwd "/tmp"
    code <<-EOH
        original_hostname=$(hostname)
        cat /etc/hosts | grep -Ev $original_hostname | sudo tee /etc/hosts
                
        echo "#{node[:drone][:ip]} mail.#{node[:drone][:domain]} mail" >> /etc/hosts
        echo "#{node[:drone][:ip]} localhost.localdomain mail" >> /etc/hosts

        service hostname restart
    EOH
end

#configure postfix

service "sendmail" do
  action :stop
end

pacakge 'postfix'
package 'opendkim'

template "/etc/postfix/main.cf" do
    source "main.cf.erb"
    mode 0664
    owner "root"
    group "root"
    variables({
        :domain => node[:drone][:domain]
    })
end

template "/etc/opendkim.conf" do
    source "opendkim.conf.erb"
    mode 0664
    owner "root"
    group "root"
    variables({
        :domain => node[:drone][:domain]
    })
end

template "/etc/default/opendkim" do
    source "opendkim.erb"
    mode 0664
    owner "root"
    group "root"
end

service "postfix" do
  action :stsrt
end

#install gems needed to run the rake tasks for speedymailer

gem_package "rubygems-update"

execute "update-gems" do          
  command "update_rubygems"
end

gem_package "albacore"
gem_package "fileutils"
gem_package "nokogiri"
gem_package "rake"

#setup mongo

service "mongodb" do
  action :stop
end

directory "/deploy/mongo-data" do
    action :create
end

execute "start-mongo" do
    command "mongod --fork --dbpath /deploy/mongo-data --port 27027 --nohttpinterface --nojournal --logpath /var/log/mongodb/drone.log"
end

#ewfresh rsyslog

script "rsyslog refresh" do
    interpreter "bash"
    user "root"
    cwd "/tmp"
    code <<-EOH
      service rsyslog stop
      service rsyslog start
    EOH
end

#deploy the drone

deploy "/deploy/drones" do
    repo "https://github.com/mamluka/SpeedyMailer.git"
    branch "master"

    symlink_before_migrate.clear
    purge_before_symlink.clear
    create_dirs_before_symlink.clear
    symlinks.clear
    
    restart_command do
        current_release = release_path
        drone_path = "#{current_release}/Out/Drone"

        execute "build-drone-with-mono" do
            cwd current_release
            command "rake mono:build"
        end

        execute "run-drone" do
           cwd drone_path

           command "mono SpeedyMailer.Drones.exe -s #{node[:drone][:master]} &"
        end

    end
end