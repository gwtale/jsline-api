'use strict'

util = require 'util'
Promise = require 'bluebird'
LineAPI = require './api'
LineModule = require './models'
LineRoom = LineModule.LineRoom
LineGroup = LineModule.LineGroup
LineContact = LineModule.LineContact
LineMessage = LineModule.LineMessage
ttypes = require 'curve-thrift/line_types'

class LineClient extends LineAPI
  constructor: (id = null, password = null, authToken = null, is_mac = false, com_name = 'CYBAI') ->
    super @config

    if not (authToken or id and password)
      throw new Error 'id and password or authToken is needed'
    
    if is_mac
      @config.Headers['X-Line-Application'] = "DESKTOPMAC\t#{@config.version}\tMAC\t10.9.4-MAVERICKS-x64"

    if authToken
      @authToken = @config.Headers['X-Line-Access'] = authToken
    else
      @_setProvider id
      @id = id
      @password = password
      @is_mac = is_mac

  login: () ->
    loginPromise = if @authToken then @_tokenLogin() else @_login @id, @password
    loginPromise.then (result) =>
      @authToken = result.authToken if result.authToken
      @certificate = result.certificate if result.certificate
      Promise.join(@getLastOpRevision(), @getProfile(), @refreshGroups(), @refreshContacts(), @refreshActiveRooms())
      .then () ->
        console.log 'Login Successfully'
        true
      , (err) ->
        console.log err
        false

  getLastOpRevision: () ->
    if @_check_auth()
      @_getLastOpRevision().then (revision) =>
        console.log "Revision is #{revision}"
        @revision = revision

  getProfile: () ->
    if @_check_auth()
      @_getProfile().then (profile) =>
        console.log 'Profile is '
        console.dir profile
        @profile = new LineContact(@, profile)

  getContactByName: (name) ->
    return contact for contact in @contacts when contact.name is name

  getContactById: (id) ->
    return contact for contact in @contacts when contact.id is id

  getContactOrRoomOrGroupById: (id) ->
    @getContactById(id) or @getRoomById(id) or @getGroupById(id)

  refreshGroups: () ->
    if @_check_auth()
      @groups = []
      @_getGroupIdsJoined().then (groupIdsJoined) =>
        console.dir groupIdsJoined
        @addGroupsWithIds groupIdsJoined
        @addGroupsWithIds groupIdsJoined, false

  addGroupsWithIds: (group_ids, is_joined = true) ->
    if @_check_auth()
      @_getGroups(group_ids).then (new_groups) =>
        console.dir new_groups
        @groups = new_groups.map (group) =>
          new LineGroup @, group, is_joined
        @groups.sort (a, b) ->
          a.id - b.id

  refreshContacts: () ->
    if @_check_auth()
      @_getAllContactIds().then (contact_ids) =>
        @_getContacts(contact_ids).then (contacts) =>
          console.dir contacts
          @contacts = contacts.map (contact) =>
            new LineContact @, contact
          @contacts.sort (a, b) ->
            a.id - b.id

  refreshActiveRooms: () ->
    if @_check_auth()
      start = 1
      count = 50
      console.log "RefreshActiveRooms with Start: #{start} and Count: #{count}"
      @rooms = []
      while true
        checkChannel = 0
        @_getMessageBoxCompactWrapUpList start, count
        .then (channel) =>
          console.dir channel
          checkChannel = channel.messageBoxWrapUpList.length
          for box in channel.messageBoxWrapUpList
            if box.messageBox.midType is ttypes.MIDType.ROOM
              @_getRoom box.messageBox.id
              .then (room) =>
                @rooms.push new LineRoom @, room
          channel
        .done (channel) ->
          console.log "Done this Channel: #{channel}"
        if checkChannel is count
            start += count
          else
            break
      true

  createGroupWithIds: (ids = []) ->
    if @_check_auth()
      @_createGroup '', ids
      .then (created) =>
        group = new LineGroup @, created
        @groups.push created
        group

  createGroupWithContacts: (name, contacts = []) ->
    if @_check_auth()
      contact_ids = (contact.id for contact in contacts)
      @_createGroup name, contact_ids
      .then (created) =>
        group = new LineGroup @, created
        @groups.push group
        group

  getGroupByName: (name) ->
    return group for group in @groups when name is group.name

  getGroupById: (id) ->
    return group for group in @groups when id is group.id

  inviteIntoGroup: (group, contacts = []) ->
    if @_check_auth()
      contact_ids = (contact.id for contact in contacts)
      @_inviteIntoGroup group.id, contact_ids

  acceptGroupInvitation: (group) ->
    if @_check_auth()
      @_acceptGroupInvitation group.id
      .then () ->
        true
      , () ->
        false

  leaveGroup: (group) ->
    if @_check_auth()
      @_leaveGroup group.id
      .then () =>
        @groups = @groups.filter (gp) ->
          gp.id isnt group.id
        true
      , () ->
        false

  createRoomWithIds: (ids = []) ->
    if @_check_auth()
      @_createRoom ids
      .then (created) =>
        room = new LineRoom @, created
        @rooms.push room
        room

  createRoomWithContacts: (contacts = []) ->
    if @_check_auth()
      contact_ids = (contact.id for contact in contacts)
      @_createRoom contact_ids
      .then (created) =>
        room = new LineRoom @, created
        @rooms.push room
        room

  getRoomById: (id) ->
    return room for room in @rooms when room.id is id

  inviteIntoRoom: (room, contacts = []) ->
    if @_check_auth()
      contact_ids = (contact.id for contact in contacts)
      @_inviteIntoRoom room.id, contact_ids

  leaveRoom: (room) ->
    if @_check_auth()
      @_leaveRoom room.id
      .then () ->
        @rooms = @rooms.filter (rm) ->
          rm.id isnt room.id
        true
      , () ->
        false

  sendMessage: (message, seq = 0) ->
    if @_check_auth()
      @_sendMessage message, seq

  getMessageBox: (id) ->
    if @_check_auth()
      @_getMessageBoxCompactWrapUp id
      .then (messageBoxWrapUp) ->
        messageBoxWrapUp.messageBox

  getRecentMessages: (messageBox, count) ->
    if @_check_auth()
      @_getRecentMessages messageBox.id, count
      .then (messages) =>
        @getLineMessageFromMessage messages

  longPoll: (count = 50) ->
    if @_check_auth()
      OT = ttypes.OpType
      TalkException = ttypes.TalkException

      try
        operations = @_fetchOperations @revision, count
      catch err
        console.dir err
        throw new Error 'user logged in on another machine' if TalkException instanceof err and err.code is 9

  createContactOrRoomOrGroupByMessage: (message) ->
    if message.toType is ttypes.MIDType.USER
      console.log message.toType
    else if message.toType is ttypes.MIDType.ROOM
      console.log message.toType
    else if message.toType is ttypes.MIDType.GROUP
      console.log message.toType

  getLineMessageFromMessage: (messages = []) ->
    messages.map (msg) =>
      new LineMessage @, msg

  _check_auth: () ->
    if @authToken
      true
    else
      throw new Error 'You need to login'

module.exports = LineClient