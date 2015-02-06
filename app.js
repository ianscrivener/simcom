var SimCom = require('./lib/simcom');
var tty = new SimCom('/dev/ttyUSB0');

tty.on('open', function() {
  console.log("ready");
  //  Give it 10 more seconds to connect to the network, then try to send an SMS 
   
  tty.serviceProvider().catch(function(err) {
    console.error("error", err);
  }).done(function(res) {
    console.log("done", res);
  });
});

