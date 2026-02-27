/* --- BANNER INJECTION --- */
(function () {
    var bannerCode =
        '░█████░░███░░░░███░███░░░██░██░████████░██░░░██░\n' +
        '██░░░██░████░░████░████░░██░██░░░░██░░░░░██░██░░\n' +
        '██░░░██░██░████░██░██░██░██░██░░░░██░░░░░░███░░░\n' +
        '██░░░██░██░░██░░██░██░░████░██░░░░██░░░░░██░██░░\n' +
        '░█████░░██░░░░░░██░██░░░███░██░░░░██░░░░██░░░██░';

    function insertBanner() {
        var userInput = document.querySelector('input[name="luci_username"]');
        if (userInput && !document.getElementById('banner')) {
            var container = document.querySelector('.cbi-map');
            if (container) {
                var style = '<style>#banner pre { font-family:monospace; line-height:1.1; color:#F37320; margin:0; font-weight:bold; white-space:pre; -webkit-text-size-adjust:none; text-size-adjust:none; font-size: min(10px, 2.5vw); }</style>';
                container.insertAdjacentHTML('afterbegin', style + '<div id="banner" style="text-align:center; margin:20px auto; width:100%;"><pre>' + bannerCode + '</pre></div>');
            }
        }
    }
    setInterval(insertBanner, 500);
})();
/* --- END INJECTION --- */