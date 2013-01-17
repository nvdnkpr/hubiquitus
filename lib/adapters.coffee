#
# * Copyright (c) Novedia Group 2012.
# *
# *    This file is part of Hubiquitus
# *
# *    Permission is hereby granted, free of charge, to any person obtaining a copy
# *    of this software and associated documentation files (the "Software"), to deal
# *    in the Software without restriction, including without limitation the rights
# *    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
# *    of the Software, and to permit persons to whom the Software is furnished to do so,
# *    subject to the following conditions:
# *
# *    The above copyright notice and this permission notice shall be included in all copies
# *    or substantial portions of the Software.
# *
# *    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# *    INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
# *    PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
# *    FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# *    ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
# *
# *    You should have received a copy of the MIT License along with Hubiquitus.
# *    If not, see <http://opensource.org/licenses/mit-license.php>.
#

url = require "url"
zmq = require "zmq"
cronJob = require("cron").CronJob
validator = require "./validator"

class Adapter

  constructor: (properties) ->
    @started = false
    if properties.owner
    then @owner = properties.owner
    else throw new Error("You must pass an actor as reference")

  start: ->
    @started = true

  stop: ->
    @started = false

class InboundAdapter extends Adapter

  constructor: (properties) ->
    @direction = "in"
    super

  genListenPort: ->
    Math.floor(Math.random() * 98)+3000

class SocketInboundAdapter extends InboundAdapter

  constructor: (properties) ->
    super
    if properties.url then @url = properties.url else @url = "tcp://127.0.0.1:#{@genListenPort}"
    @type = "socket_in"
    @sock = zmq.socket "pull"
    @sock.identity = "SocketIA_of_#{@owner.actor}"
    @sock.on "message", (data) =>
      @owner.emit "message", JSON.parse(data)

  start: ->
    unless @started
      @sock.bindSync @url
      @owner.log "debug", "#{@sock.identity} listening on #{@url}"
      super

  stop: ->
    if @started
      if @sock._zmq.state is 0
        @sock.close()
      super

class LBSocketInboundAdapter extends InboundAdapter

  constructor: (properties) ->
    super
    if properties.url then @url = properties.url else @url = "tcp://127.0.0.1:#{@genListenPort}"
    @type = "lb_socket_in"
    @sock = zmq.socket "pull"
    @sock.identity = "LBSocketIA_of_#{@owner.actor}"
    @sock.on "message", (data) => @owner.emit "message", JSON.parse(data)

  start: ->
    unless @started
      @sock.connect @url
      @owner.log "debug", "#{@sock.identity} listening on #{@url}"
      super

  stop: ->
    if @started
      if @sock._zmq.state is 0
        @sock.close()
      super

class ChannelInboundAdapter extends InboundAdapter

  constructor: (properties) ->
    @channel = properties.channel
    super
    if properties.url
    then @url = properties.url
    else throw new Error("You must provide a channel url")
    @type = "channel_in"
    @listQuickFilter = []
    @filter = properties.filter or ""
    @sock = zmq.socket "sub"
    @sock.identity = "ChannelIA_of_#{@owner.actor}"
    @sock.on "message", (data) =>
      hMessage = data.toString().replace(/^.*\$/, "")
      hMessage = JSON.parse(hMessage)
      hMessage.actor = @owner.actor
      @owner.emit "message", hMessage

  addFilter: (quickFilter) ->
    @owner.log "debug", "Add quickFilter #{quickFilter} on #{@owner.actor} ChannelIA for #{@channel}"
    @sock.subscribe(quickFilter)
    @listQuickFilter.push quickFilter

  removeFilter: (quickFilter, cb) ->
    @owner.log "debug", "Remove quickFilter #{quickFilter} on #{@owner.actor} ChannelIA for #{@channel}"
    if @sock._zmq.state is 0
      @sock.unsubscribe(quickFilter)
    index = 0
    for qckFilter in @listQuickFilter
      if qckFilter is quickFilter
        @listQuickFilter.splice(index,1)
      index++
    if @listQuickFilter.length is 0
      cb true
    else
      cb false

  start: ->
    unless @started
      @sock.connect @url
      @addFilter(@filter)
      @owner.log "debug", "#{@owner.actor} subscribe to #{@channel} on #{@url}"
      super

  stop: ->
    if @started
      if @sock._zmq.state is 0
        @sock.close()
      super

class TimerAdapter extends InboundAdapter

  constructor: (properties) ->
    super
    @properties = properties.properties
    @author = @owner.actor+"#TimerAdapter"
    @job = undefined

  startJob: =>
    current = new Date()
    msg = @owner.buildMessage(@owner.actor, "hAlert", {}, {author:@author, published:current})
    @owner.emit "message", msg

  stopJob: =>
    # This function is executed when the job stops

  launchTimer: ->
    if @properties.mode is "millisecond"
      @job = setInterval(=>
        @startJob()
      , @properties.period)
    else if @properties.mode is "crontab"
      try
        @job = new cronJob(@properties.crontab, =>
          @startJob()
        , =>
          @stopJob()
        , true, "Europe/London")
      catch err
        @owner.log "error", "Couldn't setup timer adapter : #{err}"
    else
      @owner.log "error", "Timer adapter : Unhandled mode #{@properties}"

  start: ->
    unless @started
      @launchTimer()
      @owner.log "debug", "#{@owner.actor} launch TimerAdapter"
      super

  stop: ->
    if @started
      if @properties.mode is "crontab" and @job
        @job.stop()
      else if @properties.mode is "millisecond" and @job
        clearInterval(@job)
      super

class HttpInboundAdapter extends InboundAdapter
  constructor: (properties) ->
    super

    if properties.url_path then @serverPath = properties.url_path   else @urlpath = "tcp://127.0.0.1"
    if properties.port     then @port = properties.port             else @port = 8080

    @qs = require 'querystring'
    @sys = require 'sys'
    @http = require 'http'


  start: ->
    @owner.log "debug", "Server path : #{@serverPath} Port : #{@port} is  running ..."
    server = @http.createServer (req, res) =>
      if req.method is 'POST'
        body = ""
        req.on "data", (data) ->
          body += data
        req.on "end", =>
          post_data =  @qs.parse(body)
          @owner.emit "message", @owner.buildMessage(@owner.actor, "hHttpData", post_data, {headers:req.headers})

      else if req.method is 'GET'
        req.on 'end', -> res.writeHead 200, 'ontent-Type' : 'text/plain'
        res.end()
        url_parts =  @qs.parse(req.url)
        @owner.emit "message", @owner.buildMessage(@owner.actor, "hHttpData", url_parts, {headers:req.headers})

    server.listen @port,@serverPath

class OutboundAdapter extends Adapter

  constructor: (properties) ->
    @direction = "out"
    if properties.targetActorAid
      @targetActorAid = properties.targetActorAid
    else
      throw new Error "You must provide the AID of the targeted actor"
    super

  start: ->
    super

  send: (message) ->
    throw new Error "Send method should be overriden"

class LocalOutboundAdapter extends OutboundAdapter

  constructor: (properties) ->
    super
    if properties.ref
    then @ref = properties.ref
    else throw new Error("You must explicitely pass an actor as reference to a LocalOutboundAdapter")

  start: ->
    super

  send: (message) ->
    @start() unless @started
    @ref.emit "message", message

class ChildprocessOutboundAdapter extends OutboundAdapter

  constructor: (properties) ->
    super
    if properties.ref
    then @ref = properties.ref
    else throw new Error("You must explicitely pass an actor child process as reference to a ChildOutboundAdapter")

  start: ->
    super

  stop: ->
    if @started
      @ref.kill()
    super

  send: (message) ->
    @start() unless @started
    @ref.send message

class SocketOutboundAdapter extends OutboundAdapter

  constructor: (properties) ->
    super
    if properties.url
    then @url = properties.url
    else throw new Error("You must explicitely pass a valid url to a SocketOutboundAdapter")
    @sock = zmq.socket "push"
    @sock.identity = "SocketOA_of_#{@owner.actor}_to_#{@targetActorAid}"

  start:->
    super
    @sock.connect @url
    @owner.log "debug", "#{@sock.identity} writing on #{@url}"


  stop: ->
    if @started
      if @sock._zmq.state is 0
        @sock.close()
      super

  send: (message) ->
    @start() unless @started
    @sock.send JSON.stringify(message)

class LBSocketOutboundAdapter extends OutboundAdapter

  constructor: (properties) ->
    super
    if properties.url
    then @url = properties.url
    else throw new Error("You must explicitely pass a valid url to a LBSocketOutboundAdapter")
    @sock = zmq.socket "push"
    @sock.identity = "LBSocketOA_of_#{@owner.actor}_to_#{@targetActorAid}"

  start:->

    @sock.bindSync @url
    @owner.log "debug", "#{@sock.identity} bound on #{@url}"
    super

  stop: ->
    if @started
      if @sock._zmq.state is 0
        @sock.close()
      super

  send: (message) ->
    @start() unless @started
    @sock.send JSON.stringify(message)


class ChannelOutboundAdapter extends OutboundAdapter

  constructor: (properties) ->
    properties.targetActorAid = "#{validator.getBareURN(properties.owner.actor)}"
    super
    if properties.url
    then @url = properties.url
    else throw new Error("You must explicitely pass a valid url to a ChannelOutboundAdapter")
    @sock = zmq.socket "pub"
    @sock.identity = "ChannelOA_of_#{@owner.actor}"

  start:->
    @sock.bindSync @url
    @owner.log "debug", "#{@sock.identity} streaming on #{@url}"
    super

  stop: ->
    if @started
      if @sock._zmq.state is 0
        @sock.close()
      super

  send: (hMessage) ->
    @start() unless @started
    if hMessage.headers and hMessage.headers.h_quickFilter and typeof hMessage.headers.h_quickFilter is "string"
      message = hMessage.payload.params+"$"+JSON.stringify(hMessage)
      @sock.send message
    else
      @sock.send JSON.stringify(hMessage)

class HttpOutboundAdapter extends OutboundAdapter
  constructor: (properties) ->
    super

    if properties.url             then @server_url  = properties.url                       else @server_url = "tcp://127.0.0.1"
    if properties.port            then @port = properties.port                      else @port = 8080
    if properties.path            then @path = properties.path                      else @path = "/"
    if properties.targetActorAid  then @targetActorAid = properties.targetActorAid

    console.log "HttpOutboundAdapter used -> [ url:  "+@server_url+"  port :"+@port+" path: "+@path+" targetActorAid: "+@targetActorAid+"]"

  send: (message) ->
    @start() unless @started

    @querystring = require 'querystring'
    @http = require 'http'

    # Setting the configuration
    post_options =
      host: @server_url
      port: @port
      path: @path
      method: "POST"
      headers:
        "Content-Type": "application/x-www-form-urlencoded"
        "Content-Length": JSON.stringify(message.payload).length

    post_req = @http.request(post_options, (res) ->
      res.setEncoding "utf8"
      res.on "data", (chunk) ->
        console.log "Response: " + chunk

      @status = res.statusCode
      console.log "response  :"+@status+"  ", res.headers
    )

    post_req.on "error", (e) ->
      console.log "problem with request: " + e.message

    # write parameters to post body
    post_req.write JSON.stringify(message.payload)
    post_req.end()

class SocketIOAdapter extends OutboundAdapter

  constructor: (properties) ->
    super
    @type = "socketIO"
    @sock = properties.socket
    @sock.identity = "socketIO_of_#{@owner.actor}"
    @sock.on "hMessage", (hMessage) =>
      @owner.emit "message", hMessage

  start: ->
    super

  stop: ->
    super

  send: (hMessage) ->
    @start() unless @started
    @sock.emit "hMessage", hMessage

exports.adapter = (type, properties) ->
  switch type
    when "socket_in"
      new SocketInboundAdapter(properties)
    when "lb_socket_in"
      new LBSocketInboundAdapter(properties)
    when "channel_in"
      new ChannelInboundAdapter(properties)
    when "inproc"
      new LocalOutboundAdapter(properties)
    when "fork"
      new ChildprocessOutboundAdapter(properties)
    when "socket_out"
      new SocketOutboundAdapter(properties)
    when "lb_socket_out"
      new LBSocketOutboundAdapter(properties)
    when "channel_out"
      new ChannelOutboundAdapter(properties)
    when "socketIO"
      new SocketIOAdapter(properties)
    when "timerAdapter"
      new TimerAdapter(properties)
    when "http_in"
      new HttpInboundAdapter(properties)
    when "http_out"
      new HttpOutboundAdapter(properties)
    else
      throw new Error "Incorrect type '#{type}'"

exports.InboundAdapter = InboundAdapter
exports.OutboundAdapter = OutboundAdapter