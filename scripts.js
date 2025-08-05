/*
 * Paintball NUI Script
 * Frontend logic for the paintball lobby interface
 * Handles menu rendering and communication with FiveM client
 */

document.addEventListener('DOMContentLoaded', function() {
    var menu = document.getElementById('menu');
    var menuContent = document.getElementById('menu-content');
    var scoreboardDiv = document.getElementById('scoreboard');
    var redScoreEl = document.getElementById('red-score');
    var blueScoreEl = document.getElementById('blue-score');
    var timerEl = document.getElementById('timer');
    var closeBtn = document.getElementById('close-btn');
  
    // This array will be populated with available weapons when the menu
    // opens. Each entry is an object with properties { label, hash, tint, ammo }.
    let availableWeapons = [];
  
    // Helper to send POST requests back to the client
    function sendCallback(name, data) {
      if (!data) {
        data = {};
      }
  
      var resource = 'DocsPaintball';
      if (typeof GetParentResourceName !== 'undefined') {
        resource = GetParentResourceName();
      }
  
      var url = 'https://' + resource + '/' + name;
      var requestData = JSON.stringify(data);
  
      var xhr = new XMLHttpRequest();
      xhr.open('POST', url, true);
      xhr.setRequestHeader('Content-Type', 'application/json');
      xhr.send(requestData);
    }
  
    // Converts seconds into a MM:SS format string
    function formatTimer(seconds) {
      if (typeof seconds !== 'number' || seconds < 0) {
        return '--:--';
      }
      var minutes = Math.floor(seconds / 60);
      var secs = Math.floor(seconds % 60);
      var minStr = minutes < 10 ? '0' + minutes : minutes.toString();
      var secStr = secs < 10 ? '0' + secs : secs.toString();
      return minStr + ':' + secStr;
    }
  
    // Render the lobby menu based on the data provided by the client.
    function renderMenu(data) {
      menuContent.innerHTML = '';
      const isHost = data.isHost;
      const lobby = data.lobby;
      const score = data.scoreboard || { teamKills: { 1: 0, 2: 0 }, individual: [] };
  
      // If the client provided a weapons list, cache it. We assume
      // weaponIndex values from Lua start at 1. If undefined, leave the
      // previous weapons list intact.
      if (Array.isArray(data.weapons)) {
        availableWeapons = data.weapons;
      }
  
      if (!lobby) {
        // No lobby exists; show options to create or join a lobby.
        const info = document.createElement('p');
        info.textContent = 'No lobby currently exists. You can create a new game or join an existing one.';
        info.style.marginBottom = '10px';
        info.style.textAlign = 'center';
        menuContent.appendChild(info);
  
        // Show join button. The server will handle the case when no lobby exists.
        const joinBtn = document.createElement('button');
        joinBtn.className = 'action';
        joinBtn.style.marginBottom = '10px';
        joinBtn.textContent = 'Join Lobby';
        joinBtn.onclick = function() {
          sendCallback('joinLobby');
        };
        menuContent.appendChild(joinBtn);
  
        // Build create lobby form below
        const formContainer = document.createElement('div');
        formContainer.style.borderTop = '1px solid #555';
        formContainer.style.paddingTop = '10px';
        formContainer.style.marginTop = '10px';
        menuContent.appendChild(formContainer);
  
        const formTitle = document.createElement('p');
        formTitle.textContent = 'Create Lobby';
        formTitle.style.textAlign = 'center';
        formTitle.style.marginBottom = '10px';
        formContainer.appendChild(formTitle);
  
        // Kill limit input
        const killLabel = document.createElement('label');
        killLabel.textContent = 'Kill Limit:';
        formContainer.appendChild(killLabel);
        const killInput = document.createElement('input');
        killInput.type = 'number';
        killInput.min = 1;
        killInput.max = 100;
        killInput.value = data.lobby && data.lobby.killLimit || 20;
        killInput.id = 'killLimit';
        formContainer.appendChild(killInput);
  
        // Time limit input
        const timeLabel = document.createElement('label');
        timeLabel.textContent = 'Time Limit (seconds):';
        timeLabel.style.marginTop = '10px';
        formContainer.appendChild(timeLabel);
        const timeInput = document.createElement('input');
        timeInput.type = 'number';
        timeInput.min = 0;
        timeInput.max = 3600;
        timeInput.value = data.lobby && data.lobby.timeLimit || 600;
        timeInput.id = 'timeLimit';
        formContainer.appendChild(timeInput);
  
        // Weapon selection input: only display a select when there is
        // more than one weapon to choose from. If there's just a single
        // weapon defined in Config.Weapons the host cannot change it,
        // so we omit the dropdown entirely to avoid confusing players.
        if (availableWeapons && availableWeapons.length > 1) {
          const weaponLabel = document.createElement('label');
          weaponLabel.textContent = 'Weapon:';
          weaponLabel.style.marginTop = '10px';
          formContainer.appendChild(weaponLabel);
          const weaponSelect = document.createElement('select');
          weaponSelect.id = 'weaponSelect';
          availableWeapons.forEach(function(weapon, idx) {
            const option = document.createElement('option');
            option.value = idx + 1;
            option.textContent = weapon.label || weapon.hash || 'Weapon ' + (idx + 1);
            weaponSelect.appendChild(option);
          });
          formContainer.appendChild(weaponSelect);
        }
  
        const createBtn = document.createElement('button');
        createBtn.className = 'action';
        createBtn.style.marginTop = '15px';
        createBtn.textContent = 'Create Lobby';
        createBtn.onclick = function() {
          const killVal = parseInt(killInput.value, 10) || 20;
          const timeVal = parseInt(timeInput.value, 10) || 0;
          // Determine selected weapon; default to 1 if none or parsing fails
          let weaponIndex = 1;
          const selectEl = document.getElementById('weaponSelect');
          if (selectEl && selectEl.value) {
            weaponIndex = parseInt(selectEl.value, 10) || 1;
          }
          sendCallback('createLobby', { killLimit: killVal, timeLimit: timeVal, weaponIndex: weaponIndex });
        };
        formContainer.appendChild(createBtn);
      } else {
        // A lobby exists
        if (isHost) {
          // Host view: allow editing kill/time limits and start the game
          const hostLabel = document.createElement('p');
          hostLabel.textContent = 'You are the host.';
          hostLabel.style.textAlign = 'center';
          hostLabel.style.marginBottom = '10px';
          menuContent.appendChild(hostLabel);
  
          // Kill limit input
          const killLabel = document.createElement('label');
          killLabel.textContent = 'Kill Limit:';
          menuContent.appendChild(killLabel);
          const killInput = document.createElement('input');
          killInput.type = 'number';
          killInput.min = 1;
          killInput.max = 100;
          killInput.value = lobby.killLimit || 20;
          killInput.id = 'killLimit';
          menuContent.appendChild(killInput);
  
          // Time limit input
          const timeLabel = document.createElement('label');
          timeLabel.textContent = 'Time Limit (seconds, 0 for unlimited):';
          timeLabel.style.marginTop = '10px';
          menuContent.appendChild(timeLabel);
          const timeInput = document.createElement('input');
          timeInput.type = 'number';
          timeInput.min = 0;
          timeInput.max = 3600;
          timeInput.value = lobby.timeLimit || 600;
          timeInput.id = 'timeLimit';
          menuContent.appendChild(timeInput);
  
          // Weapon selection for host: only show when multiple
          // weapons exist. If only one weapon is configured, the
          // dropdown is hidden and the weapon index defaults to 1.
          if (availableWeapons && availableWeapons.length > 1) {
            const weaponLabel = document.createElement('label');
            weaponLabel.textContent = 'Weapon:';
            weaponLabel.style.marginTop = '10px';
            menuContent.appendChild(weaponLabel);
            const weaponSelect = document.createElement('select');
            weaponSelect.id = 'weaponSelect';
            availableWeapons.forEach(function(weapon, idx) {
              const option = document.createElement('option');
              option.value = idx + 1;
              option.textContent = weapon.label || weapon.hash || 'Weapon ' + (idx + 1);
              // Preselect current lobby weapon if available
              if (lobby.weaponIndex && parseInt(lobby.weaponIndex) === idx + 1) {
                option.selected = true;
              }
              weaponSelect.appendChild(option);
            });
            menuContent.appendChild(weaponSelect);
          }
  
          const startBtn = document.createElement('button');
          startBtn.className = 'action';
          startBtn.style.marginTop = '15px';
          startBtn.textContent = 'Start Game';
          startBtn.onclick = function() {
            // Update lobby settings before starting. We call updateLobby
            // instead of createLobby because the lobby already exists. Once
            // settings are updated, trigger startGame.
            const killVal = parseInt(killInput.value, 10) || 20;
            const timeVal = parseInt(timeInput.value, 10) || 0;
            let weaponIndex = 1;
            const selectEl = document.getElementById('weaponSelect');
            if (selectEl && selectEl.value) {
              weaponIndex = parseInt(selectEl.value, 10) || 1;
            }
            sendCallback('updateLobby', {
              killLimit: killVal,
              timeLimit: timeVal,
              weaponIndex: weaponIndex
            }).then(function() {
              sendCallback('startGame');
            });
          };
          menuContent.appendChild(startBtn);
  
          const leaveBtn = document.createElement('button');
          leaveBtn.className = 'action danger';
          leaveBtn.style.marginTop = '8px';
          leaveBtn.textContent = 'Disband Lobby';
          leaveBtn.onclick = function() {
            sendCallback('leaveLobby');
          };
          menuContent.appendChild(leaveBtn);
        } else {
        // Participant view
          const info = document.createElement('p');
          info.style.textAlign = 'center';
          info.style.marginBottom = '10px';
          info.textContent = 'Waiting for host to start the game...';
          menuContent.appendChild(info);
          // Display current team assignment
          if (data.team) {
            const teamLabel = document.createElement('p');
            teamLabel.style.textAlign = 'center';
            teamLabel.style.marginBottom = '10px';
            teamLabel.innerHTML = 'You are on <strong>' + (data.team === 1 ? 'RED' : 'BLUE') + '</strong> team.';
            menuContent.appendChild(teamLabel);
          }
          // Show list of players on each team. We group the scoreboard
          // individuals by their team number. Use score.individual
          // provided by the server via refreshLobby. If undefined, show
          // empty lists.
          const players = Array.isArray(score.individual) ? score.individual : [];
          const redPlayers = players.filter(function(p) { return p.team === 1; });
          const bluePlayers = players.filter(function(p) { return p.team === 2; });
          const listContainer = document.createElement('div');
          listContainer.style.display = 'flex';
          listContainer.style.justifyContent = 'space-between';
          listContainer.style.marginTop = '10px';
          // Red team list
          const redDiv = document.createElement('div');
          redDiv.className = 'team-list red';
          const redTitle = document.createElement('p');
          redTitle.style.fontWeight = 'bold';
          redTitle.textContent = 'RED TEAM';
          redDiv.appendChild(redTitle);
          redPlayers.forEach(function(pl) {
            const pEl = document.createElement('p');
            pEl.textContent = pl.name || 'Unknown';
            redDiv.appendChild(pEl);
          });
          // Blue team list
          const blueDiv = document.createElement('div');
          blueDiv.className = 'team-list blue';
          const blueTitle = document.createElement('p');
          blueTitle.style.fontWeight = 'bold';
          blueTitle.textContent = 'BLUE TEAM';
          blueDiv.appendChild(blueTitle);
          bluePlayers.forEach(function(pl) {
            const pEl = document.createElement('p');
            pEl.textContent = pl.name || 'Unknown';
            blueDiv.appendChild(pEl);
          });
          listContainer.appendChild(redDiv);
          listContainer.appendChild(blueDiv);
          menuContent.appendChild(listContainer);
  
          // Team selection buttons: allow players to choose which team to
          // join. If the player is already on a team, we disable the
          // button for that team. This information is provided in
          // data.team. When clicked, call setTeam NUI callback.
          const buttonContainer = document.createElement('div');
          buttonContainer.style.display = 'flex';
          buttonContainer.style.justifyContent = 'space-between';
          buttonContainer.style.marginTop = '10px';
          // Red team button
          const joinRed = document.createElement('button');
          joinRed.className = 'action';
          joinRed.style.flex = '1';
          joinRed.style.marginRight = '5px';
          joinRed.textContent = data.team === 1 ? 'On Red Team' : 'Join Red Team';
          joinRed.disabled = (data.team === 1);
          joinRed.onclick = function() {
            sendCallback('setTeam', { team: 1 });
          };
          // Blue team button
          const joinBlue = document.createElement('button');
          joinBlue.className = 'action';
          joinBlue.style.flex = '1';
          joinBlue.textContent = data.team === 2 ? 'On Blue Team' : 'Join Blue Team';
          joinBlue.disabled = (data.team === 2);
          joinBlue.onclick = function() {
            sendCallback('setTeam', { team: 2 });
          };
          buttonContainer.appendChild(joinRed);
          buttonContainer.appendChild(joinBlue);
          menuContent.appendChild(buttonContainer);
  
          // Leave lobby button
          const leaveBtn = document.createElement('button');
          leaveBtn.className = 'action danger';
          leaveBtn.style.marginTop = '15px';
          leaveBtn.textContent = 'Leave Lobby';
          leaveBtn.onclick = function() {
            sendCallback('leaveLobby');
          };
          menuContent.appendChild(leaveBtn);
        }
      }
    }
  
    // Update the scoreboard overlay with new values. Accepts a
    // scoreboard object with teamKills. If undefined the values are
    // reset.
    function updateScoreboard(score) {
      // Log the full score object to see what’s being received
  
  
      if (!score) {
  
        redScoreEl.textContent = '0';
        blueScoreEl.textContent = '0';
        return;
      }
  
      const tk = score.teamKills || {};
      const redVal = tk.red ?? 0;
      const blueVal = tk.blue ?? 0;
  
      redScoreEl.textContent = redVal;
      blueScoreEl.textContent = blueVal;
    }
    
  
    // Update the timer display on the scoreboard.
    function updateTimer(seconds) {
      timerEl.textContent = formatTimer(seconds);
    }
  
    // Maintain last known host status. This is updated when the menu
    // opens. The refreshLobby message does not tell us whether we are
    // host, so we reuse the last value.
    let lastIsHost = false;
    let lastTeam = undefined;
  
    // Event listener for messages from the client script. Each message
    // instructs us to open/close menus or update overlays.
    window.addEventListener('message', function(event) {
      const data = event.data;
      switch (data.action) {
        case 'openMenu':
          menu.classList.remove('hidden');
          lastIsHost = !!data.isHost;
          lastTeam = data.team;
          renderMenu(data);
          break;
          case 'refreshLobby':
            // Update the team based on what the client sent us
            if (data.team !== undefined) {
              lastTeam = data.team;
            }
  
            // If the menu is open, update its content
            if (!menu.classList.contains('hidden')) {
              renderMenu({
                isHost: lastIsHost,
                lobby: data.lobby,
                scoreboard: data.scoreboard,
                team: lastTeam,
              });
            }
            break;
          
        case 'closeMenu':
          menu.classList.add('hidden');
          break;
        case 'showScoreboard':
          scoreboardDiv.classList.remove('hidden');
          updateScoreboard(data.scoreboard);
          updateTimer(data.timer);
          break;
        case 'updateScoreboard':
          updateScoreboard(data.scoreboard);
          break;
        case 'updateTimer':
          updateTimer(data.timer);
          break;
        case 'hideScoreboard':
          scoreboardDiv.classList.add('hidden');
          break;
      }
    });
  
    // Close button hides the menu but does not leave the lobby. The
    // callback simply tells the client to close the NUI focus.
    closeBtn.addEventListener('click', function() {
      sendCallback('closeMenu');
    });
  })();