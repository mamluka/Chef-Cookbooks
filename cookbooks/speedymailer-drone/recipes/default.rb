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

#add backports repo
script "add-backport-deb" do
    interpreter "bash"
    user "root"
    cwd "/tmp"
    code <<-EOH
      echo 'deb http://archive.ubuntu.com/ubuntu precise-backports main restricted universe multiverse' >> /etc/apt/sources.list
    EOH
end

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

#stop apache - we don't need it

service "apache2" do
  action :stop
end

#install mono

apt_repository "mono-rep" do
  uri "http://ppa.launchpad.net/borgdylan/ppa/ubuntu"
  distribution node['lsb']['codename']
  components ["main"]
  keyserver "keyserver.ubuntu.com"
  key "4B47C289FADDF7CF01380548FAAB7362B99C283A"
  deb_src true

  not_if "cat /etc/apt/sources.list.d/* | grep borgdylan"
end

apt_repository "rsyslog" do
  uri "http://ppa.launchpad.net/ukplc-team/testing/ubuntu"
  distribution node['lsb']['codename']
  components ["main"]
  keyserver "keyserver.ubuntu.com"
  key "F262AA585E04325397D7C8BA1C7DAF1E1A39EA92"
  deb_src true

  not_if "cat /etc/apt/sources.list.d/* | grep ukplc-team"
end

package 'rsyslog'

execute "stop-rsyslog-service" do
  command "ps aux | grep rsyslog | grep -v grep | awk '{print $2}' | xargs kill -9"
end

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

package 'postfix'
package 'postfix-pcre'
package 'dk-filter'

script "install-open-dkim" do
    interpreter "bash"
    user "root"
    cwd "/tmp"
    code <<-EOH
      apt-get install opendkim/precise-backports opendkim-tools/precise-backports -y
    EOH
end

template "/etc/postfix/main.cf" do
    source "main.cf.erb"
    mode 0664
    owner "root"
    group "root"
    variables({
        :domain => node[:drone][:domain]
    })
end

template "/etc/postfix/header_checks" do
    source "header_checks"
    mode 0664
    owner "root"
    group "root"
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

template "/etc/default/dk-filter" do
    source "dk-filter.erb"
    mode 0664
    owner "root"
    group "root"
     variables({
        :domain => node[:drone][:domain]
    })
end

script "create-dkim-key" do
    interpreter "bash"
    user "root"
    cwd "/tmp"
    code <<-EOH
      opendkim-genkey -t -s mail -d #{node[:drone][:domain]}
      cp mail.private /etc/mail/dkim.key
      cp mail.txt /root/dkim-dns.txt
    EOH
end

script "create-domain-key" do
    interpreter "bash"
    user "root"
    cwd "/tmp"
    code <<-EOH
      openssl genrsa -out private.key 1024
      openssl rsa -in private.key -out public.key -pubout -outform PEM
      cp private.key /etc/mail/domainkey.key
      cp public.key /root/domain-keys-dns.txt
      service dk-filter stop
      service dk-filter start
    EOH
end

service "postfix" do
  action :start
end

service "opendkim" do
  action :restart
end

#install gems needed to run the rake tasks for speedymailer

gem_package "rubygems-update"

execute "update-gems" do          
  command "update_rubygems"
end

gem_package "albacore" do
  not_if "gem list | grep albacore"
end

gem_package "nokogiri" do
  not_if "gem list | grep nokogiri"
end

gem_package "rake" do
  not_if "gem list | grep rake"
end

#setup mongo

service "mongodb" do
  action :stop
end

directory "/deploy/mongo-data" do
    action :create
    recursive true
    not_if "test -d /deploy/mongo-data"
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
      sed -i '/imklog/d' /etc/rsyslog.conf
      service rsyslog stop
      service rsyslog start
    EOH
end

execute "setup-port-forwarding" do
  command "iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080"
  not_if " iptables -t nat -L -n -v | grep 8080"
end

#deploy scripts

directory "/root/bin" do
    action :create
    recursive true
end

template "/root" do
    source ".bash_profile.erb"
    mode 0664
    owner "root"
    group "root"
end

template "/root" do
    source ".bash_profile.erb"
    mode 0664
    owner "root"
    group "root"
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
        
        execute "kill-running-drone" do
           cwd drone_path
           command "ps aux | grep mono | grep -v grep | awk '{print $2}' | xargs kill -9"
           only_if "ps aux | grep mono | grep -v grep"
        end

        execute "run-drone" do
           cwd drone_path
           command "nohup mono SpeedyMailer.Drones.exe -s #{node[:drone][:master]} &"
        end
    end
end
