#
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
include_recipe "ruby::symlinks"
include_recipe "rubygems"
include_recipe "rake"
include_recipe "postfix::client"
include_recipe "mongodb"

package 'libgvc5'
package 'libgraphviz-dev'
package 'libmagickcore-dev'
package 'libmagickcore4-extra'
package 'libmagickwand-dev'
package 'libxslt-dev'
package 'libxml2-dev'
package 'mailutils'
package 'curl'

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
package 'mono-runtime'
package 'mono-devel'

#set host to be a mail server

file "/etc/hostname" do
     content "mail"
end

#setup rsyslog logging to mongo

script "config-syslog" do
    interpreter "bash"
    user "root"
    cwd "/tmp"
    code <<-EOH
        sudo sh -c 'echo "$ModLoad ommongodb" >> /etc/rsyslog.conf'
        sudo sh -c 'echo "mail.* action(type=\"ommongodb\" server=\"127.0.0.1\")" >> /etc/rsyslog.conf'
        sudo service rsyslog restart
    EOH
end

#set the domain in the hosts file


script "add-domain-to-hosts-file" do
    interpreter "bash"
    user "root"
    cwd "/tmp"
    code <<-EOH
        original_hostname=$(hostname)
        cat /etc/hosts | grep -Ev $original_hostname | sudo tee /etc/hosts

        echo "#{node[:ipaddress]} mail.#{node[:drone][:domain]} mail" >> /etc/hosts
        echo "127.0.0.1 mail" >> /etc/host

        service hostname restart
    EOH
end

#configure postfix

template "/etc/postfix/main.cf" do
    source "main.cf.erb"
    mode 0664
    owner "root"
    group "root"
    variables({
        :domain => node[:drone][:domain]
    })
end

#install gems needed to run the rake tasks for speedymailer
execute "install-gems" do
  command "gem install nokogiri fileutils albacore"
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

        directory "/deploy/mongo-data" do
            action :create
        end

        execute "start-mongo" do
            command "mongod --dbpath /deploy/mongo-data --port 27027 --nohttpinterface --nojournal &"
        end

        execute "run-drone" do
           cwd drone_path

           command "mono SpeedyMailer.Drones.exe -s #{node[:drone][:master]} &"
        end

    end
end


