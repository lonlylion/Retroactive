//
//  iLifeMediaBrowser.m  (Retroactive shim)
//
//  macOS 26 dropped a number of exported symbols from the system iLifeMediaBrowser private
//  framework that Aperture and iPhoto import (non-weak), so they fail to bind at load. This shim
//  re-exports the live system framework (see build.tool) and supplies the missing symbols.
//
//  The string constants are plugin identifiers / attribute keys used only by the media-browser
//  integration; their exact values affect that (secondary) feature, not core app functionality.
//

#import <Foundation/Foundation.h>

#define IL_CONST(name) NSString * const name = @#name

// Used by Aperture
IL_CONST(ILAppDefFolderPluginIdentifier);

// Used by iPhoto
IL_CONST(ILFolderPluginIdentifier);
IL_CONST(ILGarageBandPluginIdentifier);
IL_CONST(ILiPhotoPluginIdentifier);
IL_CONST(ILiTunesPluginIdentifier);
IL_CONST(ILiPhotoShowInvisibleItemsAttributeKey);
IL_CONST(ILiPhotoShowTrashAlbumAttributeKey);
IL_CONST(ILiPhotoTimeMachineDBasePathAttributeKey);
IL_CONST(ILiPhotoUseTimeMachineDBasePathAttributeKey);
IL_CONST(ILiTunesArtistKey);
IL_CONST(ILiTunesNameKey);
IL_CONST(ILMediaObjectArtistKey);
IL_CONST(ILMediaObjectDurationAttribute);

// NSRectPoint is a (lazily-bound) function iPhoto calls via iLifeMediaBrowser; macOS 26 dropped
// it. It is not used on any core path — provide a harmless no-op.
void NSRectPoint(void) { }
