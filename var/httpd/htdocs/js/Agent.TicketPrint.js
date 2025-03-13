// --
// OTOBO is a web-based ticketing system for service organisations.
// --
// Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
// Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
// --
// This program is free software: you can redistribute it and/or modify it under
// the terms of the GNU General Public License as published by the Free Software
// Foundation, either version 3 of the License, or (at your option) any later version.
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
// FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
// --

"use strict";

var Core = Core || {};
Core.Agent = Core.Agent || {};

/**
 * @namespace Core.Agent.TicketPrint
 * @memberof Core.Agent
 * @author
 * @description
 *      This namespace contains the special module functions for TicketPrint.
 */
Core.Agent.TicketPrint = (function (TargetNS) {

    /**
     * @name InitWidgets
     * @memberof Core.Agent.TicketZoom
     * @function
     * @param {Object} AsyncWidgetActions - list of widgets to initialize
     * @description
     *      This function initializes configured asynchronous widgets.
     */
    function InitWidgets(AsyncWidgetActions) {
        $.each(AsyncWidgetActions, function (ElementID, URLPart) {
            Core.AJAX.ContentUpdate($('#' + ElementID), Core.Config.Get('Baselink') + URLPart, function() {

                // wait for content update
                $('#' + ElementID).find("a.AsPopup").on('click', function () {
                    var Matches,
                        PopupType = 'TicketAction';

                    Matches = $(this).attr('class').match(/PopupType_(\w+)/);
                    if (Matches) {
                        PopupType = Matches[1];
                    }

                    Core.UI.Popup.OpenPopup($(this).attr('href'), PopupType);
                    return false;
                });

                $('#' + ElementID).find('.WidgetSimple').hide().fadeIn();
                Core.UI.InitWidgetActionToggle();
            });
        });
    }

    /**
     * @name IFrameResize
     * @memberof Core.Agent.TicketPrint
     * @function
     * @param {Object} IFrame - the iframe element
     * @description
     *      This function resizes an iframe to it's content height.
     */
    /*TargetNS.IFrameResize = function (IFrame) {
console.log("IFrameResize Called on " + typeof(IFrame));
        IFrame.height = IFrame.contentWindow.document.body.scrollHeight + "px";
    };*/

    /**
     * @name IframeAutoHeight
     * @memberof AdvancedTicketPrint.Agent.TicketPrint
     * @function
     * @param {jQueryObject} $Iframe - The iframe which should be auto-heighted
     * @description
     *      Set iframe height automatically based on real content height.
     */
    TargetNS.IframeAutoHeight = function ($Iframe) {

        var NewHeight,
            IframeContentHeight

        if (isJQueryObject($Iframe)) {
            // slightly change the width of the iframe to not be exactly 100% width anymore
            // this prevents a double horizontal scrollbar (from iframe and surrounding div)
            //$Iframe.width('calc(100%-2px)');

            let IframeContents = $Iframe.contents();
            if (IframeContents) {
                IframeContentHeight = IframeContents.find('html').height();
            }
            
            // if the iFrames height is 0, we collapse the widget
            if (!IframeContentHeight || isNaN(IframeContentHeight)) {
                NewHeight = 0;
            }
            else {
                NewHeight = IframeContentHeight + 5;
            }

            // add delta for scrollbar
            /*if (NewHeight > 0) {
                NewHeight = parseInt(NewHeight, 10) + 25;
            }*/

            $Iframe.height(NewHeight + 'px');
            //console.log('NewHeight: ' + NewHeight);
        }
    };

    /**
     * @name Init
     * @memberof Core.Agent.TicketZoom
     * @function
     * @description
     *      This function initializes the special module functions.
     */
    TargetNS.Init = function () {

        let AsyncWidgetActions = Core.Config.Get('AsyncWidgetActions') || {};

        InitWidgets(AsyncWidgetActions);

    };
    
    Core.Init.RegisterNamespace(TargetNS, 'APP_MODULE');

    return TargetNS;

}(Core.Agent.TicketPrint || {}));
