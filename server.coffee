express = require 'express'
bodyParser = require 'body-parser'
mongodb = require 'mongodb'
config = require 'config'
log4js = require 'log4js'

# Configuration options
#=================================================================
url = config.get 'mongo.url'
port = config.get 'express.port'

# Logger config
#=================================================================
log4js.configure
    appenders: config.get('log4js.appenders')
logger = log4js.getLogger 'app'
logger.setLevel(config.get('log4js.level'))

# Web app config
#=================================================================
app = express()

# Middleware
app.use(bodyParser.json())
app.use (req, res, next)->
    logger.info("#{req.method} #{req.path}")
    next()

# Bootstrap
#=================================================================
bootstrap = app.bootstrap = (code)->
    mongodb.MongoClient.connect url, (err, _db)->
        if err
            logger.error "Error: #{err}"
            return

        app.ObjectId = mongodb.ObjectId
        app.db = _db
        app.items = _db.collection('items')
        code()

# Template
#=================================================================
view = (data)->
    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <title>Short Link Privacy Message</title>
        <style type="text/css">
            body { font-family: sans-serif; background-color: #fff; }
            #content { width: 500px; margin-left: auto; margin-right: auto; }
            .slp {}
            .slp a { color: #00f; font-weight: bold; }
            pre { background-color: #eee; padding: 10px; border: 1px dotted #aaa; overflow-y: auto; }
            #decrypt { text-decoration: none; border-bottom: 1px dotted blue; font-size: .8em; }
        </style>
      </head>
      <body>
        <div id="content">
            <h1>PGP Encrypted Message</h1>
            <p class="slp">
                Please install the <a href="https://chrome.google.com/webstore/detail/short-link-privacy/kkhoekeemmabphdemkfakkjjmpfkjocm">Short Link Privacy</a> browser
                plugin to have this message decrypt in your browser.
            </p>
            <div> <a id="decrypt" href="#">decrypt here</a> </div>
            <pre id="msg">
    """ + data.body + """
            </pre>
            <small class="footer">
                <a href="https://en.wikipedia.org/wiki/Pretty_Good_Privacy">What is PGP?</a> |
                <a href="/">What is SLP?</a>
            </small>
        </div>
        <script>
           document.getElementById('decrypt').addEventListener('click', function(e) {
            e.preventDefault();
            var el = document.createElement('pre');
            el.innerText = location.href;
            this.parentElement.appendChild(el);
            this.parentElement.removeChild(this);
           });

          (function(i,s,o,g,r,a,m){i['GoogleAnalyticsObject']=r;i[r]=i[r]||function(){
          (i[r].q=i[r].q||[]).push(arguments)},i[r].l=1*new Date();a=s.createElement(o),
          m=s.getElementsByTagName(o)[0];a.async=1;a.src=g;m.parentNode.insertBefore(a,m)
          })(window,document,'script','//www.google-analytics.com/analytics.js','ga');

          ga('create', 'UA-74656221-2', 'auto');
          ga('send', 'pageview');

        </script>
      </body>
    </html>
    """

# Routes
#=================================================================
app.get '/x/:id', (req, res)->

    id = req.params.id
    objId = null

    # Must be an ObjectId
    try
        objId = new mongodb.ObjectId id
    catch e
        return res.sendStatus 404

    # Find the id in items
    app.items.findOne { _id: objId,  }, (err, result)->
        if err?
            logger.error "findOne(#{id}) returned error: #{err}"
            res.sendStatus 500
        else if result?

            if result.timeToLive
                now = new Date()
                createdDate = result.createdDate
                if createdDate.getTime() + result.timeToLive * 1000 < now.getTime()
                    res.statusCode = 410
                    res.send "Expired"
                    return

            if req.get('Content-Type') is "application/json"
                res.statusCode = 200
                res.json
                    body: result.body
                    timeToLive: result.timeToLive
                    createdDate: result.createdDate
                    fingerprints: result.fingerprints
                    _id: result._id
            else
                res.statusCode = 200
                res.send view(result)
        else
            res.sendStatus 404


app.post '/x', (req, res)->
    #logger.trace "req.headers", req.headers
    #logger.trace "req.body", req.body
    payload = req.body

    err400 = (msg)->
        res.statusCode = 400
        res.json { error: msg }

    if not payload?
        return err400 "payload missing"

    unless payload.body?
        return err400 "body not defined"

    # Limit the size of messages, so fools don't use this as a key value store
    if payload.body.length > 10000
        return err400 "message too long"

    # IP Address
    payload.ip = req.header('x-real-ip')

    # Creation date
    payload.createdDate = new Date()

    # Save
    app.items.insertOne payload, (err, result)->
        if err?
            logger.error "insertOne (#{payload}) resulted in error: #{err}"
            res.sendStatus = 500
        else
            res.statusCode = 201
            res.json { id: result.insertedId }


# Main
#=================================================================
if require.main == module
    bootstrap ->
        app.listen port, ->
            logger.info "The server is running on port #{port}"

module.exports = app
