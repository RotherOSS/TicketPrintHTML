# --
# OTOBO is a web-based ticketing system for service organisations.
# --
# Copyright (C) 2001-2020 OTRS AG, https://otrs.com/
# Copyright (C) 2019-2025 Rother OSS GmbH, https://otobo.io/
# --
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 3 of the License, or (at your option) any later version.
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
# --

package Kernel::Modules::AgentTicketPrint;

use strict;
use warnings;
use utf8;

our $ObjectManagerDisabled = 1;

# core modules
use List::Util qw(any);
use POSIX      qw(ceil);
use File::stat qw(stat);

# CPAN modules
use PDF::API2 ();

# OTOBO modules
use Kernel::System::VariableCheck qw(:all);
use Kernel::Language              qw(Translatable);
use Kernel::Modules::AdvancedTicketPrint;

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = bless {%Param}, $Type;

    # set debug
    $Self->{Debug} = 0;

    # get needed objects
    my $ParamObject  = $Kernel::OM->Get('Kernel::System::Web::Request');
    
    $Self->{ArticleID} = $ParamObject->GetParam( Param => 'ArticleID' ) || '';
    
    return $Self;
}

sub Run {
    my ( $Self, %Param ) = @_;

    # get layout object
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    # check needed stuff
    if ( !$Self->{TicketID} ) {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('No TicketID is given!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    # get needed objects
    my $TicketObject = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # check permissions
    my $Access = $TicketObject->TicketPermission(
        Type     => 'ro',
        TicketID => $Self->{TicketID},
        UserID   => $Self->{UserID}
    );

    # error screen, don't print ticket
    return $LayoutObject->NoPermission(
        Message => Translatable(
            "This ticket does not exist, or you don't have permissions to access it in its current state."
        ),
        WithHeader => 'no',
    ) if !$Access;

    # get ticket attributes
    my %Ticket = $TicketObject->TicketGet(
        TicketID      => $Self->{TicketID},
        DynamicFields => 1,
    );

    my %PossibleActions;
    my $Counter = 0;

    # get all registered Actions
    if ( ref $ConfigObject->Get('Frontend::Module') eq 'HASH' ) {

        my %Actions = %{ $ConfigObject->Get('Frontend::Module') };

        # only use those Actions that stats with Agent
        %PossibleActions = map { ++$Counter => $_ }
            grep { substr( $_, 0, length 'Agent' ) eq 'Agent' }
            sort keys %Actions;
    }

    my $ACL = $TicketObject->TicketAcl(
        Data          => \%PossibleActions,
        Action        => $Self->{Action},
        TicketID      => $Self->{TicketID},
        ReturnType    => 'Action',
        ReturnSubType => '-',
        UserID        => $Self->{UserID},
    );

    my %AclAction = %PossibleActions;
    if ($ACL) {
        %AclAction = $TicketObject->TicketAclActionData();
    }

    # check if ACL restrictions exist
    my %AclActionLookup = reverse %AclAction;

    # show error screen if ACL prohibits this action
    if ( !$AclActionLookup{ $Self->{Action} } ) {
        return $LayoutObject->NoPermission( WithHeader => 'no' );
    }

    # send parameter TicketID to JS
    $LayoutObject->AddJSData(
        Key   => 'TicketID',
        Value => $Self->{TicketID},
    );

    if ($Self->{Subaction} && $Self->{Subaction} eq 'PrintAction') {

        return $Self->_CreateHTMLContent(
            TicketAttributes => \%Ticket,
            AclAction => \%AclAction
        );

    } else {

        $Self->_PrintPDF();

        # TODO: Error handling

        # return the document as string
        my $pdf = PDF::API2->open('var/tmp/output.pdf');
        
        my $PDFString = $pdf->stringify();
        $pdf->end();

        # Assemble file name.
        my $DateTimeObject = $Kernel::OM->Create('Kernel::System::DateTime');

        if ( $Self->{UserTimeZone} ) {
            $DateTimeObject->ToTimeZone( TimeZone => $Self->{UserTimeZone} );
        }
        my $Filename = 'Ticket_' . $Ticket{TicketNumber} . '_';
        $Filename .= $DateTimeObject->Format( Format => '%Y-%m-%d_%H:%M' );
        $Filename .= '.pdf';

        my $CleanedFilename = $Kernel::OM->Get('Kernel::System::Main')->FilenameCleanUp(
            Filename => $Filename,
            Type     => 'Attachment',
        );

        return $LayoutObject->Attachment(
            Filename    => $CleanedFilename,
            ContentType => "application/pdf",
            Content     => $PDFString,
            Type        => 'inline',
        );
    }

}

sub _CreateHTMLContent {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    for my $Needed (qw(TicketAttributes AclAction)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    my %Ticket = %{ $Param{TicketAttributes} };
    my %AclAction = %{ $Param{AclAction} };

    # get layout object
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    if ( !$Self->{TicketID} ) {
        return $LayoutObject->ErrorScreen(
            Message => Translatable('No TicketID is given!'),
            Comment => Translatable('Please contact the administrator.'),
        );
    }

    # get needed objects
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # get required objects
    my $ParamObject = $Kernel::OM->Get('Kernel::System::Web::Request');
    my $MainObject  = $Kernel::OM->Get('Kernel::System::Main');

    if ( $Self->{Subaction} eq 'LoadWidget' ) {
        my $ElementID = $ParamObject->GetParam( Param => 'ElementID' );
        my $Config;
        WIDGET:
        for my $Key ( sort keys %{ $Self->{DisplaySettings}->{Widgets} // {} } ) {
            if ( $ElementID eq 'Async_' . $LayoutObject->LinkEncode($Key) ) {
                $Config = $Self->{DisplaySettings}->{Widgets}->{$Key};
                last WIDGET;
            }
        }
        if ($Config) {
            my $Success = eval { $MainObject->Require( $Config->{Module} ) };
            if ( !$Success ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "Cannot load $Config->{Module}: $@",
                );
                return $LayoutObject->Attachment(
                    ContentType => 'text/html',
                    Content     => '',
                    Type        => 'inline',
                    NoCache     => 1,
                );
            }
            my $Module = eval { $Config->{Module}->new( %{$Self} ) };
            if ( !$Module ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  => "new() of Widget module $Config->{Module} not successful!",

                );
                return $LayoutObject->Attachment(
                    ContentType => 'text/html',
                    Content     => '',
                    Type        => 'inline',
                    NoCache     => 1,
                );
            }
            my $WidgetOutput = $Module->Run(
                Ticket    => \%Ticket,
                AclAction => \%AclAction,
                Config    => $Config,
            );

            return $LayoutObject->Attachment(
                ContentType => 'text/html',
                Content     => $WidgetOutput->{Output} // ' ',
                Type        => 'inline',
                NoCache     => 1,
                Charset     => 'utf-8',
            );
        }
        else {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Cannot locate module for ElementID $ElementID",
            );
            return $LayoutObject->Attachment(
                ContentType => 'text/html',
                Content     => '',
                Type        => 'inline',
                NoCache     => 1,
            );
        }
    }

    # get needed objects
    my $UserObject    = $Kernel::OM->Get('Kernel::System::User');
    my $SessionObject = $Kernel::OM->Get('Kernel::System::AuthSession');

    # generate output
    return join '',
        $LayoutObject->Header(
            Value               => $Ticket{TicketNumber},
            TicketID            => $Ticket{TicketID},
            ShowToolbarItems    => 0,
            ShowPrefLink        => 0,
            ShowLogoutButton    => 0,
            Type                => 'Small',
        ),
        $Self->MaskAgentPrint(
            Ticket    => \%Ticket,
            AclAction => \%AclAction
        ),
        $LayoutObject->Footer;

}

sub _PrintPDF {
    my ( $Self, %Param ) = @_;

    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');

    # build URL
    my $URL = $ConfigObject->Get('HttpType')
        . '://'
#        . $ConfigObject->Get('FQDN')
#        . 'localhost'
        . 'host.docker.internal'
        . '/'
        . $ConfigObject->Get('ScriptAlias')
        . 'index.pl?Action=AgentTicketPrint;Subaction=PrintAction;TicketID=' . $Self->{TicketID};

print STDERR 'Print URL: ' . $URL . "\n";
    
    my $ChromePath = $ConfigObject->Get('GoogleChrome::Bin');
    if ( !$ChromePath ) {
        # TODO: add error message
        return 0;
    }
    my $CommandResult = `cd var/tmp; '$ChromePath' --headless --print-to-pdf --virtual-time-budget=25000 --run-all-compositor-stages-before-draw '$URL' 2>&1`;

    #TODO: log command output??
    return $CommandResult;
}

sub MaskAgentPrint {
    my ( $Self, %Param ) = @_;

    my %Ticket    = %{ $Param{Ticket} };
    my %AclAction = %{ $Param{AclAction} };

    # get needed objects
    my $TicketObject  = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');

    # Create a list of article sender types for lookup
    my %ArticleSenderTypeList = $ArticleObject->ArticleSenderTypeList();

    # fetch all move queues
    my %MoveQueues = $TicketObject->MoveList(
        TicketID => $Ticket{TicketID},
        UserID   => $Self->{UserID},
        Action   => 'AgentTicketMove',
        Type     => 'move_into',
    );

    # fetch all std. templates
    my %StandardTemplates = $Kernel::OM->Get('Kernel::System::Queue')->QueueStandardTemplateMemberList(
        QueueID       => $Ticket{QueueID},
        TemplateTypes => 1,
    );

    # get config object
    my $ConfigObject = $Kernel::OM->Get('Kernel::Config');


    my $Limit = $ConfigObject->Get('PDF::MaxPages');
    my $Order = $Self->{ArticleSort} eq 'reverse' ? 'DESC' : 'ASC';
    
    # get param object
    my $ParamObject = $Kernel::OM->Get('Kernel::System::Web::Request');

    my $IsVisibleForCustomer;
    if ( defined $Self->{ArticleFilter}->{CustomerVisibility} ) {
        $IsVisibleForCustomer = $Self->{ArticleFilter}->{CustomerVisibility};
    }

    # Get all articles.
    my @ArticleBox = $ArticleObject->ArticleList(
        TicketID             => $Self->{TicketID},
        IsVisibleForCustomer => $IsVisibleForCustomer,
        ShowDeletedArticles  => $Self->{ShowDeletedArticles}
    );

    if ( IsArrayRefWithData( $Self->{ArticleFilter}->{CommunicationChannelID} ) ) {
        my %Filter = map { $_ => 1 } @{ $Self->{ArticleFilter}->{CommunicationChannelID} };

        @ArticleBox = grep { $Filter{ $_->{CommunicationChannelID} } } @ArticleBox;
    }

    if ( IsArrayRefWithData( $Self->{ArticleFilter}->{ArticleSenderTypeID} ) ) {
        my %Filter = map { $_ => 1 } @{ $Self->{ArticleFilter}->{ArticleSenderTypeID} };

        @ArticleBox = grep { $Filter{ $_->{SenderTypeID} } } @ArticleBox;
    }

    if ( $Order eq 'DESC' ) {
        @ArticleBox = reverse @ArticleBox;
    }

    my %ArticleFlags = $ArticleObject->ArticleFlagsOfTicketGet(
        TicketID => $Ticket{TicketID},
        UserID   => $Self->{UserID},
    );

    # show only specified article
    if ( $Self->{ArticleID}) {
        ARTICLE:
        for my $Article (@ArticleBox) {
            next ARTICLE if !$Article->{ArticleID};
            next ARTICLE if $Self->{ArticleID} ne $Article->{ArticleID};

            @ArticleBox = ($Article);
        }
    }

    @ArticleBox = $Self->_ArticleBoxGet(
        ArticleBoxAll => \@ArticleBox,
        Limit         => $Limit
    );

    # get layout object
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    # age design
    $Ticket{Age} = $LayoutObject->CustomerAge(
        Age   => $Ticket{Age},
        Space => ' '
    );

    my $MainObject = $Kernel::OM->Get('Kernel::System::Main');

    my %Widgets;
    my %AsyncWidgetActions;
    WIDGET:
    for my $Key ( sort keys %{ $Self->{DisplaySettings}->{Widgets} // {} } ) {
        my $Config = $Self->{DisplaySettings}->{Widgets}->{$Key};

        if ( $Config->{Async} ) {
            if ( !$Config->{Location} ) {
                $Kernel::OM->Get('Kernel::System::Log')->Log(
                    Priority => 'error',
                    Message  =>
                        "The configuration for $Config->{Module} must contain a Location, because it is marked as Async.",
                );
                next WIDGET;
            }
            my $ElementID = 'Async_' . $LayoutObject->LinkEncode($Key);
            push @{ $Widgets{ $Config->{Location} } }, {
                Async => 1,
                Rank  => $Config->{Rank} || $Key,
                %Ticket,
                ElementID => $ElementID,
            };
            $AsyncWidgetActions{$ElementID} = "Action=$Self->{Action};Subaction=LoadWidget;"
                . "TicketID=$Self->{TicketID};ElementID=$ElementID";
            next WIDGET;
        }
        my $Success = eval { $MainObject->Require( $Config->{Module} ) };

        next WIDGET unless $Success;

        my $Module = eval { $Config->{Module}->new(%$Self) };
        if ( !$Module ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "new() of Widget module $Config->{Module} not successful!",

            );

            next WIDGET;
        }

        my $WidgetOutput = $Module->Run(
            Ticket    => \%Ticket,
            AclAction => \%AclAction,
            Config    => $Config,
        );

        next WIDGET unless $WidgetOutput;

        $WidgetOutput->{Rank} //= $Key;
        my $Location = $WidgetOutput->{Location} || $Config->{Location};
        push @{ $Widgets{$Location} }, $WidgetOutput;
    }
    for my $Location ( sort keys %Widgets ) {
        $Param{ $Location . 'Widgets' } = [
            sort { $a->{Rank} cmp $b->{Rank} } @{ $Widgets{$Location} }
        ];
    }
    $LayoutObject->AddJSData(
        Key   => 'AsyncWidgetActions',
        Value => \%AsyncWidgetActions,
    );

    # set display options
    $Param{Hook} = $ConfigObject->Get('Ticket::Hook') || 'Ticket#';

    # only show article tree if articles are present,
    # or if a filter is set (so that the user has the option to
    # disable the filter)
    if ( @ArticleBox || $Self->{ArticleFilter} ) {

        $Param{ShowArticleList} = $Self->{DisplaySettings}{ShowArticleList} || 0;

        # show article tree
        $Param{ArticleTree} = $Self->_ArticleTree(
            Ticket            => \%Ticket,
            ArticleFlags      => \%ArticleFlags,
            ArticleID         => $Self->{ArticleID},
            ArticleMaxLimit   => $Limit,
            ArticleBox        => \@ArticleBox,
            ArticleCount      => scalar @ArticleBox,
            AclAction         => \%AclAction,
            StandardResponses => $StandardTemplates{Answer},
            StandardForwards  => $StandardTemplates{Forward},
        );
    }

    my @ArticleIDs;
    $Param{ArticleItems} = '';

    my $ArticleWidgetsHTML = '';

    ARTICLE:
    for my $ArticleTmp (@ArticleBox) {
        my %Article = %$ArticleTmp;

        $ArticleWidgetsHTML .= $Self->_ArticleItem(
            Ticket            => \%Ticket,
            Article           => \%Article,
            AclAction         => \%AclAction,
            StandardResponses => $StandardTemplates{Answer},
            StandardForwards  => $StandardTemplates{Forward},
            ActualArticleID   => $Self->{ArticleID},
            Type              => 'Static',
        );
        push @ArticleIDs, $ArticleTmp->{ArticleID};
    }

    # send data to JS
    $LayoutObject->AddJSData(
        Key   => 'ArticleIDs',
        Value => \@ArticleIDs,
    );
    $LayoutObject->AddJSData(
        Key   => 'MenuItems',
        Value => $Self->{MenuItems},
    );

    $Param{ArticleItems} .= $LayoutObject->Output(
        TemplateFile => 'AgentTicketPrint',
        Data         => {
            %Ticket,
            %AclAction,
            ArticleWidgetsHTML => $ArticleWidgetsHTML,
        },
    );

    # always show archived tickets as seen
    if ( $Ticket{ArchiveFlag} ne 'y' ) {

        # send data to JS
        $LayoutObject->AddJSData(
            Key   => 'TicketItemMarkAsSeen',
            Value => 1,
        );
    }

    # number of articles
    $Param{ArticleCount} = scalar @ArticleBox;

    # print logo
    $Param{PDFLogo} = '';
    if ( $Self->{DisplaySettings}{PrintLogoFile} && $ConfigObject->Get('Frontend::WebPath')) {
        $Param{PDFLogo} = $ConfigObject->Get('Frontend::WebPath') . $Self->{DisplaySettings}{PrintLogoFile};
    }

    $LayoutObject->Block(
        Name => 'Header',
        Data => { %Param, %Ticket, %AclAction },
    );

    my %ActionLookup;
    my $UserObject = $Kernel::OM->Get('Kernel::System::User');

    # show created by if different then User ID 1
    if ( $Ticket{CreateBy} > 1 ) {

        # get user object
        my $UserObject = $Kernel::OM->Get('Kernel::System::User');
        $Ticket{CreatedByUser} = $UserObject->UserName( UserID => $Ticket{CreateBy} );
        $LayoutObject->Block(
            Name => 'CreatedBy',
            Data => {%Ticket},
        );
    }

    # show no articles block if ticket does not contain articles
    if ( !@ArticleBox ) {
        $LayoutObject->Block(
            Name => 'HintNoArticles',
        );
    }

    # collect data for overview widget
    my %WidgetData;
    my $NoOfDynamicFields = keys %{$Self->{DisplaySettings}{DynamicField} // {}};

    if ( $NoOfDynamicFields >= 0 ) {
        %WidgetData =
            (
                WidgetDisplay            => $Self->{DisplaySettings}{DynamicFieldWidgetDisplay},
                WidgetTitle              => $Self->{DisplaySettings}{DynamicFieldWidgetDisplay}{WidgetTitle},
                WidgetDynamicFieldGroups => $Self->{DisplaySettings}{DynamicFieldWidgetDynamicFieldGroups},
            );

        $WidgetData{WidgetDynamicField} = $ConfigObject->Get("Ticket::Frontend::AgentTicketPrint")
            ->{ ( 'DynamicField' ) } // {};

    }

    # decide if widget should be shown
    my $ShowWidget = 0;

    # show only if dynamic fields are defined and at least one of them has a value
    if ( IsHashRefWithData( $WidgetData{WidgetDynamicField} ) ) {
        DFVALUE:
        for my $FieldName ( keys $WidgetData{WidgetDynamicField}->%* ) {
            next DFVALUE unless $Ticket{"DynamicField_$FieldName"};

            $ShowWidget = 1;

            last DFVALUE;
        }
    }

    # show overview widget with dynamic field data
    if ($ShowWidget) {

        # send data to JS
        $LayoutObject->AddJSData(
            Key   => 'OverviewWidget',
            Value => 1,
        );

        # output the overview widget in the main screen
        $LayoutObject->Block(
            Name => 'OverviewWidget',
            Data => {
                WidgetTitle => $WidgetData{WidgetTitle},
            },
        );

        # get dynamic field config for frontend module
        my $DynamicFieldFilter = {
            %{ $ConfigObject->Get("Ticket::Frontend::AgentTicketPrint")->{DynamicField} || {} },
            %{
                $WidgetData{WidgetDynamicField} || {}
            },
        };

        # get the dynamic fields for ticket object
        my $DynamicField = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldListGet(
            Valid       => 1,
            ObjectType  => ['Ticket'],
            FieldFilter => $DynamicFieldFilter || {},
        );
        my $DynamicFieldBackendObject = $Kernel::OM->Get('Kernel::System::DynamicField::Backend');

        # to store dynamic fields to be displayed in the overview widget
        my (@FieldsWidget);

        # cycle trough the activated Dynamic Fields for ticket object
        DYNAMICFIELD:
        for my $DynamicFieldConfig ( @{$DynamicField} ) {
            next DYNAMICFIELD if !IsHashRefWithData($DynamicFieldConfig);
            next DYNAMICFIELD if !defined $Ticket{ 'DynamicField_' . $DynamicFieldConfig->{Name} };
            next DYNAMICFIELD if $Ticket{ 'DynamicField_' . $DynamicFieldConfig->{Name} } eq '';

            # use translation here to be able to reduce the character length in the template
            my $Label = $LayoutObject->{LanguageObject}->Translate( $DynamicFieldConfig->{Label} );

            if ( $WidgetData{WidgetDynamicField}{ $DynamicFieldConfig->{Name} } ) {

                my $ValueStrg = $DynamicFieldBackendObject->ReadableValueRender(
                    DynamicFieldConfig => $DynamicFieldConfig,
                    Value              => $Ticket{ 'DynamicField_' . $DynamicFieldConfig->{Name} },
                );

                push @FieldsWidget, {
                    $DynamicFieldConfig->{Name} => $ValueStrg->{Title},
                    Name                        => $DynamicFieldConfig->{Name},
                    Title                       => $ValueStrg->{Title},
                    Value                       => $ValueStrg->{Value},
                    ValueKey                    => $Ticket{ 'DynamicField_' . $DynamicFieldConfig->{Name} },
                    Label                       => $Label,
                    Link                        => $ValueStrg->{Link},
                    LinkPreview                 => $ValueStrg->{LinkPreview},

                    # Include unique parameter with dynamic field name in case of collision with others.
                    #   Please see bug#13362 for more information.
                    "DynamicField_$DynamicFieldConfig->{Name}" => $ValueStrg->{Title},
                };
            }
        }

        $LayoutObject->Block(
            Name => 'OverviewWidgetDynamicFieldGroups',
        );

        for my $Field (@FieldsWidget) {

            $LayoutObject->Block(
                Name => 'OverviewWidgetDynamicField',
            );

            my ($DFConfig) = grep { $_->{Name} eq $Field->{Name} } $DynamicField->@*;

            # set field
            if ( $DFConfig->{FieldType} eq 'Set' ) {

                $LayoutObject->Block(
                    Name => 'SetField',
                );

                $LayoutObject->Block(
                    Name => 'DynamicFieldSetSeparator',
                    Data => {
                        Name => $Field->{Name},
                    },
                );

                my @IncludedFields = $Self->_GetIncludedFieldOrdered(
                    Include => $DFConfig->{Config}{Include},
                );

                for my $IncludeField (@IncludedFields) {

                    my $IncludeDFConfig = $Kernel::OM->Get('Kernel::System::DynamicField')->DynamicFieldGet(
                        Name => $IncludeField,
                    );
                    my $ValueStrg = $DynamicFieldBackendObject->DisplayValueRender(
                        DynamicFieldConfig => $IncludeDFConfig,
                        Value              => $Ticket{ 'DynamicField_' . $IncludeDFConfig->{Name} },
                        LayoutObject       => $LayoutObject,

                        # no ValueMaxChars here, enough space available
                    );

                    my %IncludeField = (
                        $IncludeDFConfig->{Name} => $ValueStrg->{Title},
                        Name                     => $IncludeDFConfig->{Name},
                        Title                    => $ValueStrg->{Title},
                        Value                    => $ValueStrg->{Value},
                        ValueKey                 => $Ticket{ 'DynamicField_' . $IncludeDFConfig->{Name} },
                        Label                    => $IncludeDFConfig->{Label},
                        Link                     => $ValueStrg->{Link},
                        LinkPreview              => $ValueStrg->{LinkPreview},

                        # Include unique parameter with dynamic field name in case of collision with others.
                        #   Please see bug#13362 for more information.
                        "DynamicField_$IncludeDFConfig->{Name}" => $ValueStrg->{Title},
                    );
                    $LayoutObject->Block(
                        Name => 'SetDynamicField',
                        Data => {
                            Name  => $IncludeField{Name},
                            Label => $IncludeField{Label},
                        }
                    );
                    
                    if ( $IncludeDFConfig->{Link} ) {
                        $LayoutObject->Block(
                            Name => 'SetDynamicFieldLink',
                            Data => {
                                $IncludeField{Name} => $IncludeField{Title},
                                %Ticket,

                                # alias for ticket title, Title will be overwritten
                                TicketTitle => $Ticket{Title},
                                Value       => $IncludeField{Value},
                                Title       => $IncludeField{Title},
                                Link        => $IncludeField{Link},
                                LinkPreview => $IncludeField{LinkPreview},

                                # Include unique parameter with dynamic field name in case of collision with others.
                                #   Please see bug#13362 for more information.
                                "DynamicField_$IncludeField{Name}" => $IncludeField{Title},
                            },
                        );
                    }
                    else {
                        $LayoutObject->Block(
                            Name => 'SetDynamicFieldPlain',
                            Data => {
                                Value => $IncludeField{Value},
                                Title => $IncludeField{Title},
                            },
                        );
                    }
                    # push @FieldsInAGroup, $Field->{Name};
                }
            }

            # standard field
            else {
                $LayoutObject->Block(
                    Name => 'StandardField',
                    Data => {
                        Name  => $Field->{Name},
                        Label => $Field->{Label},
                    },
                );


                $LayoutObject->Block(
                    Name => 'OverviewWidgetDynamicFieldPlain',
                    Data => {
                        Value => $Field->{Value},
                        Title => $Field->{Title},
                    },
                );

            }

        }
    }

    $LayoutObject->AddJSData(
        Key   => 'Language',
        Value => {
            AttachmentViewMessage => Translatable(
                'Article could not be opened! Perhaps it is on another article page?'
            ),
        },
    );

    # return output
    return $LayoutObject->Output(
        TemplateFile => 'AgentTicketPrint',
        Data         => { %Param, %Ticket, %AclAction },
    );
}

sub _ArticleTree {
    my ( $Self, %Param ) = @_;

    my %Ticket          = %{ $Param{Ticket} };
    my %ArticleFlags    = %{ $Param{ArticleFlags} };
    my @ArticleBox      = @{ $Param{ArticleBox} };
    my $ArticleMaxLimit = $Param{ArticleMaxLimit};
    my $ArticleID       = $Param{ArticleID};
    my $TableClasses;

    # get layout object
    my $LayoutObject = $Kernel::OM->Get('Kernel::Output::HTML::Layout');



    # build thread string
    $LayoutObject->Block(
        Name => 'Tree',
        Data => {
            %Param,
            TableClasses => $TableClasses,
            ZoomTimeline => 0,
        },
    );

    # get needed objects
    my $TicketObject  = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $ConfigObject  = $Kernel::OM->Get('Kernel::Config');

    # Create a list of article sender types for lookup
    my %ArticleSenderTypeList = $ArticleObject->ArticleSenderTypeList();

    # show article tree
    $LayoutObject->Block(
        Name => 'ArticleList',
        Data => {
            %Param,
            ZoomExpandSortOrder => $Self->{ArticleSort} eq 'reverse' ? 'Descending' : 'Ascending',
            TableClasses        => $TableClasses,
        },
    );

    ARTICLE:
    for my $ArticleTmp (@ArticleBox) {
        my %Article = %$ArticleTmp;

        # show article flags
        my $Class      = '';
        my $ClassRow   = '';
        my $NewArticle = 0;

        # ignore system sender types
        if (
            !$ArticleFlags{ $Article{ArticleID} }->{Seen}
            && (
                !$ConfigObject->Get('Ticket::NewArticleIgnoreSystemSender')
                || $ConfigObject->Get('Ticket::NewArticleIgnoreSystemSender')
                && $ArticleSenderTypeList{ $Article{SenderTypeID} } ne 'system'
            )
            )
        {
            $NewArticle = 1;

            # show ticket flags

            # always show archived tickets as seen
            if ( $Ticket{ArchiveFlag} ne 'y' ) {
                $Class    .= ' UnreadArticles';
                $ClassRow .= ' UnreadArticles';
            }

            # just show ticket flags if agent belongs to the ticket
            my $ShowMeta;
            if (
                $Self->{UserID} == $Ticket{OwnerID}
                || $Self->{UserID} == $Ticket{ResponsibleID}
                )
            {
                $ShowMeta = 1;
            }
            if ( !$ShowMeta && $ConfigObject->Get('Ticket::Watcher') ) {
                my %Watch = $TicketObject->TicketWatchGet(
                    TicketID => $Article{TicketID},
                );
                if ( $Watch{ $Self->{UserID} } ) {
                    $ShowMeta = 1;
                }
            }

            # show ticket flags
            if ($ShowMeta) {
                $Class .= ' Remarkable';
            }
            else {
                $Class .= ' Ordinary';
            }
        }

        my $TmpSubject = $TicketObject->TicketSubjectClean(

            TicketNumber => $Ticket{TicketNumber},
            Subject      => $Article{Subject} || '',
        );

        my %ArticleFields = $LayoutObject->ArticleFields(
            %Article,
            ShowDeletedArticles => $Self->{ShowDeletedArticles}
        );

        # Get transmission status information for email articles.
        my $TransmissionStatus;
        if ( $Article{ChannelName} && $Article{ChannelName} eq 'Email' ) {
            $TransmissionStatus = $ArticleObject->BackendForArticle(%Article)->ArticleTransmissionStatus(
                ArticleID           => $Article{ArticleID},
                ShowDeletedArticles => $Self->{ShowDeletedArticles}
            );
        }

        $LayoutObject->Block(
            Name => 'TreeItem',
            Data => {
                %Article,
                ArticleFields      => \%ArticleFields,
                Class              => $Class,
                ClassRow           => $ClassRow,
                Subject            => $TmpSubject,
                TransmissionStatus => $TransmissionStatus,
                ZoomExpand         => 1,
                ZoomExpandSort     => $Self->{ArticleSort},
            },
        );

        # get article flags
        # Always use user id 1 because other users also have to see the important flag
        my %ArticleImportantFlags = $ArticleObject->ArticleFlagGet(
            ArticleID => $Article{ArticleID},
            UserID    => 1,
        );

        # show important flag
        if ( $ArticleImportantFlags{Important} ) {
            $LayoutObject->Block(
                Name => 'TreeItemImportantArticle',
                Data => {},
            );
        }

        # always show archived tickets as seen
        if ( $NewArticle && $Ticket{ArchiveFlag} ne 'y' ) {
            $LayoutObject->Block(
                Name => 'TreeItemNewArticle',
                Data => {
                    %Article,
                    Class => $Class,
                },
            );
        }

        # Bugfix for IE7: a table cell should not be empty
        # (because otherwise the cell borders are not shown):
        # we add an empty element here
        else {
            $LayoutObject->Block(
                Name => 'TreeItemNoNewArticle',
                Data => {},
            );
        }

        # Determine communication direction.
        if ( $Article{ChannelName} eq 'Internal' ) {
            $LayoutObject->Block( Name => 'TreeItemDirectionInternal' );
        }
        elsif ( $ArticleSenderTypeList{ $Article{SenderTypeID} } eq 'customer' ) {
            $LayoutObject->Block( Name => 'TreeItemDirectionIncoming' );
        }
        else {
            $LayoutObject->Block( Name => 'TreeItemDirectionOutgoing' );
        }

    }

    # return output
    return $LayoutObject->Output(
        TemplateFile => 'AgentTicketPrint',
        Data         => { %Param, %Ticket },
    );
}

sub _ArticleItem {
    my ( $Self, %Param ) = @_;

    my %Ticket    = %{ $Param{Ticket} };
    my %Article   = %{ $Param{Article} };
    my %AclAction = %{ $Param{AclAction} };

    my $TicketObject  = $Kernel::OM->Get('Kernel::System::Ticket');
    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my $LayoutObject  = $Kernel::OM->Get('Kernel::Output::HTML::Layout');

    my $RenderedArticle = $Self->_ArticleRender(
        TicketID               => $Ticket{TicketID},
        ArticleID              => $Article{ArticleID},
        UserID                 => $Self->{UserID},
        ShowBrowserLinkMessage => 1,
        Type                   => $Param{Type},
        ShowDeletedArticles    => $Self->{ShowDeletedArticles}
    );

    return $RenderedArticle;
}

sub _ArticleBoxGet {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    for my $Needed (qw(ArticleBoxAll Limit)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    my $ArticleObject = $Kernel::OM->Get('Kernel::System::Ticket::Article');
    my @ArticleBoxAll = @{ $Param{ArticleBoxAll} };

    my $Start = 0;
    my $End = $Param{Limit} - 1;

    my $LastArticleIndex = scalar @{ $Param{ArticleBoxAll} } - 1;
    if ( $LastArticleIndex < $End) {
        $End = $LastArticleIndex
    }

    my $CommunicationChannelObject = $Kernel::OM->Get('Kernel::System::CommunicationChannel');

    # Save communication channel data to improve performance.
    my %CommunicationChannelData;

    my @ArticleBox;
    for my $Index ($Start .. $End) {
        my $ArticleBackendObject = $ArticleObject->BackendForArticle(
            TicketID            => $Self->{TicketID},
            ArticleID           => $Param{ArticleBoxAll}->[$Index]->{ArticleID},
            ShowDeletedArticles => $Self->{ShowDeletedArticles}
        );

        my %Article = $ArticleBackendObject->ArticleGet(
            TicketID      => $Self->{TicketID},
            ArticleID     => $Param{ArticleBoxAll}->[$Index]->{ArticleID},
            DynamicFields => 1,
            RealNames     => 1,
        );

        # Include some information about communication channel.
        if ( !$CommunicationChannelData{ $Article{CommunicationChannelID} } ) {

            # Communication channel display name is part of the configuration.
            my %CommunicationChannel = $CommunicationChannelObject->ChannelGet(
                ChannelID => $Article{CommunicationChannelID},
            );

            # Presence of communication channel object indicates its validity.
            my $ChannelObject = $CommunicationChannelObject->ChannelObjectGet(
                ChannelID => $Article{CommunicationChannelID},
            );

            $CommunicationChannelData{ $Article{CommunicationChannelID} } = {
                ChannelName        => $CommunicationChannel{ChannelName},
                ChannelDisplayName => $CommunicationChannel{DisplayName},
                ChannelInvalid     => !$ChannelObject,
            };
        }

        %Article = ( %Article, %{ $CommunicationChannelData{ $Article{CommunicationChannelID} } } );

        push @ArticleBox, \%Article;
    }

    return @ArticleBox;
}

=head2 _ArticleRender()

Returns article html.

    my $HTML = $Self->_ArticleRender(
        TicketID               => 123,      # (required)
        ArticleID              => 123,      # (required)
        Type                   => 'Static', # (required) Static or OnLoad
        ShowBrowserLinkMessage => 1,        # (optional)
    );

Result:
    $HTML = "<div>...</div>";

=cut

sub _ArticleRender {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    for my $Needed (qw(TicketID ArticleID Type)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!",
            );
            return;
        }
    }

    # Get article data.
    my $ArticleBackendObject = $Kernel::OM->Get('Kernel::System::Ticket::Article')->BackendForArticle(%Param);

    # Determine channel name for this Article.
    my $ChannelName = $ArticleBackendObject->ChannelNameGet();

    my $Loaded = $Kernel::OM->Get('Kernel::System::Main')->Require(
        "Kernel::Output::HTML::TicketZoom::Agent::$ChannelName",
    );
    return if !$Loaded;

    return $Kernel::OM->Get("Kernel::Output::HTML::TicketZoom::Agent::$ChannelName")->ArticleRender(
        %Param,
        ArticleActions => $Param{MenuItems},
        UserID         => $Self->{UserID},
    );
}

sub _GetIncludedFieldOrdered {
    my ( $Self, %Param ) = @_;

    my @Return;

    ITEM:
    for my $IncludeItem ( @{ $Param{Include} } ) {

        if ( $IncludeItem->{Grid} ) {
            for my $Row ( @{ $IncludeItem->{Grid}{Rows} } ) {

                COLUMN:
                for my $DFEntry ( $Row->@* ) {
                    next COLUMN if !$DFEntry->{DF};

                    push @Return, $DFEntry->{DF};
                }
            }
        }
        elsif ( $IncludeItem->{DF} ) {
            push @Return, $IncludeItem->{DF};
        }
    }

    return @Return;
}

1;
