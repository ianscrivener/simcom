var restify = require('restify');
var SimCom = require('./lib/simcom');
var tty = new SimCom('/dev/ttyUSB0');

tty.on('open', function() {
  console.log("ready");
  //  Give it 10 more seconds to connect to the network, then try to send an SMS 
   
  tty.tryConnectOperator().then(function(res) {
    console.log("getServiceProvider2", res);
    tty.getLastError();
  }).then(function(res) {
    console.log("getLastError", res);
  }).catch(function(err) {
    console.error("error", err);
  }).done(function(res) {
    console.log("done", res);

  });

  tty.tryConnectOperator(function(err, res){
    console.log(err, res);
  });

});

var server = restify.createServer({ name: 'my-api' });
server.use(restify.fullResponse()).use(restify.bodyParser());

server.get('/status', function (req, res, next) {

});