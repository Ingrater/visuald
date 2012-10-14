// This file is part of Visual D
//
// Visual D integrates the D programming language into Visual Studio
// Copyright (c) 2010 by Rainer Schuetze, All Rights Reserved
//
// License for redistribution is given by the Artistic License 2.0
// see file LICENSE for further details

module visuald.propertypage;

import visuald.windows;

import sdk.win32.objbase;
import sdk.vsi.vsshell;
import sdk.vsi.vsshell80;

import visuald.comutil;
import visuald.logutil;
import visuald.dpackage;
import visuald.dproject;
import visuald.dllmain;
import visuald.config;
import visuald.winctrl;
import visuald.hierarchy;
import visuald.hierutil;

import stdext.array;
import std.string;
import std.conv;

class PropertyWindow : Window
{
	this(Widget parent, uint style, string title, PropertyPage page)
	{
		mPropertyPage = page;
		super(parent, style, title);
	}

	override int WindowProc(HWND hWnd, uint uMsg, WPARAM wParam, LPARAM lParam) 
	{
		switch (uMsg) {
			case WM_SIZE:
				int w = LOWORD(lParam);
				mPropertyPage.updateSizes(w);
				break;
			default:
				break;
		}
		return super.WindowProc(hWnd, uMsg, wParam, lParam);
	}

	PropertyPage mPropertyPage;
}

abstract class PropertyPage : DisposingComObject, IPropertyPage, IVsPropertyPage, IVsPropertyPage2
{
	/*const*/ int kPageWidth = 370;
	/*const*/ int kPageHeight = 210;
	/*const*/ int kMargin = 4;
	/*const*/ int kLabelWidth = 120;
	/*const*/ int kTextHeight = 20;
	/*const*/ int kLineHeight = 23;
	/*const*/ int kLineSpacing = 2;
	/*const*/ int kNeededLines = 10;

	override HRESULT QueryInterface(in IID* riid, void** pvObject)
	{
		if(queryInterface!(IPropertyPage) (this, riid, pvObject))
			return S_OK;
		if(queryInterface!(IVsPropertyPage) (this, riid, pvObject))
			return S_OK;
		if(queryInterface!(IVsPropertyPage2) (this, riid, pvObject))
			return S_OK;
		return super.QueryInterface(riid, pvObject);
	}

	override void Dispose()
	{
		mSite = release(mSite);

		foreach(obj; mObjects)
			release(obj);
		mObjects.length = 0;

		mResizableWidgets = mResizableWidgets.init;

		mDlgFont = deleteDialogFont(mDlgFont);
	}

	override int SetPageSite( 
		/* [in] */ IPropertyPageSite pPageSite)
	{
		mixin(LogCallMix);
		mSite = release(mSite);
		mSite = addref(pPageSite);
		return S_OK;
	}

	override int Activate( 
		/* [in] */ in HWND hWndParent,
		/* [in] */ in RECT *pRect,
		/* [in] */ in BOOL bModal)
	{
		mixin(LogCallMix);
		
		if(mWindow)
			return returnError(E_FAIL);
		return _Activate(new Window(hWndParent), pRect, bModal);
	}
	
	int _Activate( 
		/* [in] */ Window win,
		/* [in] */ in RECT *pRect,
		/* [in] */ in BOOL bModal)
	{
		if(pRect)
			logCall("_Activate(" ~ to!string(*pRect) ~ ")");
		RECT pr;
		win.GetWindowRect(&pr);
		logCall("  parent.rect = " ~ to!string(pr) ~ "");

		if(HWND phwnd = GetParent(win.hwnd))
		{
			GetWindowRect(phwnd, &pr);
			logCall("  parent.parent.rect = " ~ to!string(pr) ~ "");
		}
		if(pRect)
			kPageWidth = pRect.right - pRect.left;

		updateEnvironmentFont();
		if(!mDlgFont)
			mDlgFont = newDialogFont();

		mWindow = win;
		mCanvas = new Window(mWindow);
		DWORD color = GetSysColor(COLOR_BTNFACE);
		mCanvas.setBackground(color);
		mCanvas.setRect(kMargin, kMargin, kPageWidth - 2 * kMargin, kPageHeight - 2 * kMargin);
		mResizableWidgets ~= mCanvas;

		// avoid closing canvas (but not dialog) if pressing esc in MultiLineEdit controls
		//mCanvas.cancelCloseDelegate ~= delegate bool(Widget c) { return true; };
		
		class DelegateWrapper
		{
			void OnCommand(Widget w, int cmd)
			{
				UpdateDirty(true);
			}
		}

		CreateControls();
		UpdateControls();

		DelegateWrapper delegateWrapper = new DelegateWrapper;
		mCanvas.commandDelegate = &delegateWrapper.OnCommand;
		mEnableUpdateDirty = true;

		return S_OK;
	}

	override int Deactivate()
	{
		mixin(LogCallMix);
		if(mWindow)
		{
			mWindow.Dispose();
			mWindow = null;
			mCanvas = null;
		}

		return S_OK;
		//return returnError(E_NOTIMPL);
	}

	void updateSizes(int width)
	{
		foreach(w; mResizableWidgets)
		{
			RECT r;
			if(w && w.hwnd)
			{
				w.GetWindowRect(&r);
				r.right = width - kMargin;
				w.SetWindowPos(null, &r, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
			}
		}
	}

	void calcMetric()
	{
		updateEnvironmentFont();
		kMargin = 4;

		if(!mDlgFont)
			mDlgFont = newDialogFont();
		HWND hwnd = GetDesktopWindow();
		HDC dc = GetDC(hwnd);
		SelectObject(dc, mDlgFont);
		TEXTMETRIC tm;
		GetTextMetrics(dc, &tm);
		ReleaseDC(hwnd, dc);

		int fHeight = tm.tmHeight;
		int fWidth = tm.tmAveCharWidth;

		kPageWidth = fWidth * 75 + 2 * kMargin;
		kLabelWidth = fWidth * 22;
		mUnindentCheckBox = kLabelWidth;

		kLineSpacing = 2;
		kTextHeight = fHeight + 4;
		kLineHeight = kTextHeight + kLineSpacing + 1;
		kPageHeight = kLineHeight * kNeededLines + 2 * kMargin;
	}

	override int GetPageInfo( 
		/* [out] */ PROPPAGEINFO *pPageInfo)
	{
		mixin(LogCallMix);

		if(pPageInfo.cb < PROPPAGEINFO.sizeof)
			return E_INVALIDARG;

		calcMetric();
		pPageInfo.cb = PROPPAGEINFO.sizeof;
		pPageInfo.pszTitle = string2OLESTR("Title");
		pPageInfo.size = visuald.comutil.SIZE(kPageWidth, kPageHeight);
		pPageInfo.pszHelpFile = string2OLESTR("HelpFile");
		pPageInfo.pszDocString = string2OLESTR("DocString");
		pPageInfo.dwHelpContext = 0;

		return S_OK;
	}

	override int SetObjects( 
		/* [in] */ in ULONG cObjects,
		/* [size_is][in] */ IUnknown *ppUnk)
	{
		mixin(LogCallMix2);

		foreach(obj; mObjects)
			release(obj);
		mObjects.length = 0;
		for(uint i = 0; i < cObjects; i++)
			mObjects ~= addref(ppUnk[i]);

		if(mWindow)
		{
			mEnableUpdateDirty = false;
			UpdateControls();
			mEnableUpdateDirty = true;
		}

		return S_OK;
	}

	override int Show( 
		/* [in] */ in UINT nCmdShow)
	{
		logCall("%s.Show(nCmdShow=%s)", this, _toLog(nCmdShow));
		if(mWindow)
			mWindow.setVisible(true);
		return S_OK;
		//return returnError(E_NOTIMPL);
	}

	override int Move( 
		/* [in] */ in RECT *pRect)
	{
		mixin(LogCallMix);
		return returnError(E_NOTIMPL);
	}

	override int Help( 
		/* [in] */ in wchar* pszHelpDir)
	{
		logCall("%s.Help(pszHelpDir=%s)", this, _toLog(pszHelpDir));
		return returnError(E_NOTIMPL);
	}

	override int TranslateAccelerator( 
		/* [in] */ in MSG *pMsg)
	{
		mixin(LogCallMix2);
		if(mSite)
			return mSite.TranslateAccelerator(pMsg);
		return returnError(E_NOTIMPL);
	}

	// IVsPropertyPage
	override int CategoryTitle( 
		/* [in] */ in UINT iLevel,
		/* [retval][out] */ BSTR *pbstrCategory)
	{
		logCall("%s.get_CategoryTitle(iLevel=%s, pbstrCategory=%s)", this, _toLog(iLevel), _toLog(pbstrCategory));
		switch(iLevel)
		{
		case 0:
			if(GetCategoryName().length == 0)
				return S_FALSE;
			*pbstrCategory = allocBSTR(GetCategoryName());
			break;
		case 1:
			return S_FALSE;
			//*pbstrCategory = allocBSTR("CategoryTitle1");
		default:
			break;
		}
		return S_OK;
	}

	// IVsPropertyPage2
	override int GetProperty( 
		/* [in] */ in VSPPPID propid,
		/* [out] */ VARIANT *pvar)
	{
		mixin(LogCallMix);
		switch(propid)
		{
		case VSPPPID_PAGENAME:
			pvar.vt = VT_BSTR;
			pvar.bstrVal = allocBSTR(GetPageName());
			return S_OK;
		default:
			break;
		}
		return returnError(DISP_E_MEMBERNOTFOUND);
	}

	override int SetProperty( 
		/* [in] */ in VSPPPID propid,
		/* [in] */ in VARIANT var)
	{
		mixin(LogCallMix);
		return returnError(E_NOTIMPL);
	}

	///////////////////////////////////////
	void UpdateDirty(bool bDirty)
	{
		if(mEnableUpdateDirty && mSite)
			mSite.OnStatusChange(PROPPAGESTATUS_DIRTY | PROPPAGESTATUS_VALIDATE);
	}

	void AddControl(string label, Widget w)
	{
		int x = kLabelWidth;
		CheckBox cb = cast(CheckBox) w;
		//if(cb)
		//	cb.cmd = 1; // enable actionDelegate

		int lines = 1;
		if(MultiLineText mt = cast(MultiLineText) w)
		{
			lines = mLinesPerMultiLine;
		}
		int labelWidth = 0;
		if(label.length)
		{
			Label lab = new Label(mCanvas, label);
			int off = ((kLineHeight - kLineSpacing) - 16) / 2;
			labelWidth = w ? kLabelWidth : kPageWidth - 2*kMargin;
			lab.setRect(0, mLines*kLineHeight + off, labelWidth, kLineHeight - kLineSpacing); 
		} 
		else if (cb)
		{
			x -= mUnindentCheckBox;
		}
		int h = lines * kLineHeight - kLineSpacing;
		if(cast(Text) w && lines == 1)
		{
			h = kTextHeight;
		}
		else if(cb)
			h -= 2;
		//else if(cast(ComboBox) w)
		//    h -= 4;

		int y = mLines*kLineHeight + (lines * kLineHeight - kLineSpacing - h) / 2;
		if(w)
			w.setRect(x, y, kPageWidth - 2*kMargin - labelWidth, h); 
		mLines += lines;
		if(w)
			mResizableWidgets ~= w;
	}

	int changeOption(V)(V val, ref V optval, ref V refval)
	{
		if(refval == val)
			return 0;
		optval = val;
		return 1;
	}
	int changeOptionDg(V)(V val, void delegate (V optval) setdg, V refval)
	{
		if(refval == val)
			return 0;
		setdg(val);
		return 1;
	}

	abstract void CreateControls();
	abstract void UpdateControls();
	abstract string GetCategoryName();
	abstract string GetPageName();

	Widget[] mResizableWidgets;
	HFONT mDlgFont;
	IUnknown[] mObjects;
	IPropertyPageSite mSite;
	Window mWindow;
	Window mCanvas;
	bool mEnableUpdateDirty;
	int mLines;
	int mLinesPerMultiLine = 4;
	int mUnindentCheckBox = 120; //16;
}

///////////////////////////////////////////////////////////////////////////////
class ProjectPropertyPage : PropertyPage, ConfigModifiedListener 
{
	abstract void SetControls(ProjectOptions options);
	abstract int  DoApply(ProjectOptions options, ProjectOptions refoptions);

	override HRESULT QueryInterface(in IID* riid, void** pvObject)
	{
		//if(queryInterface!(ConfigModifiedListener) (this, riid, pvObject))
		//	return S_OK;
		return super.QueryInterface(riid, pvObject);
	}

	override void UpdateControls()
	{
		if(ProjectOptions options = GetProjectOptions())
			SetControls(options);
	}

	override void Dispose()
	{
		if(auto cfg = GetConfig())
			cfg.RemoveModifiedListener(this);

		super.Dispose();
	}

	override void OnConfigModified()
	{
	}

	override int SetObjects(/* [in] */ in ULONG cObjects,
							/* [size_is][in] */ IUnknown *ppUnk)
	{
		if(auto cfg = GetConfig())
			cfg.RemoveModifiedListener(this);
		
		int rc = super.SetObjects(cObjects, ppUnk);
		
		if(auto cfg = GetConfig())
			cfg.AddModifiedListener(this);

		return rc;
	}

	Config GetConfig()
	{
		if(mObjects.length > 0)
		{
			auto config = ComPtr!(Config)(mObjects[0]);
			return config;
		}
		return null;
	}
	ProjectOptions GetProjectOptions()
	{
		if(auto cfg = GetConfig())
			return cfg.GetProjectOptions();
		return null;
	}

	/*override*/ int IsPageDirty()
	{
		mixin(LogCallMix);
		if(mWindow)
			if(ProjectOptions options = GetProjectOptions())
			{
				scope ProjectOptions opt = new ProjectOptions(false, false);
				return DoApply(opt, options) > 0 ? S_OK : S_FALSE;
			}
		return S_FALSE;
	}

	/*override*/ int Apply()
	{
		mixin(LogCallMix);

		if(ProjectOptions refoptions = GetProjectOptions())
		{
			// make a copy, otherwise changes will no longer be detected after the first configuration
			auto refopt = clone(refoptions);
			for(int i = 0; i < mObjects.length; i++)
			{
				auto config = ComPtr!(Config)(mObjects[i]);
				if(config)
				{
					DoApply(config.ptr.GetProjectOptions(), refopt);
					config.SetDirty();
				}
			}
			return S_OK;
		}
		return returnError(E_FAIL);
	}
}

class NodePropertyPage : PropertyPage
{
	abstract void SetControls(CFileNode node);
	abstract int  DoApply(CFileNode node, CFileNode refnode);

	override void UpdateControls()
	{
		if(CFileNode node = GetNode())
			SetControls(node);
	}

	CFileNode GetNode()
	{
		if(mObjects.length > 0)
		{
			auto node = ComPtr!(CFileNode)(mObjects[0]);
			if(node)
				return node;
		}
		return null;
	}

	/*override*/ int IsPageDirty()
	{
		mixin(LogCallMix);
		if(mWindow)
			if(CFileNode node = GetNode())
			{
				scope CFileNode n = newCom!CFileNode("");
				return DoApply(n, node) > 0 ? S_OK : S_FALSE;
			}
		return S_FALSE;
	}

	/*override*/ int Apply()
	{
		mixin(LogCallMix);

		if(CFileNode refnode = GetNode())
		{
			for(int i = 0; i < mObjects.length; i++)
			{
				auto node = ComPtr!(CFileNode)(mObjects[i]);
				if(node)
				{
					DoApply(node, refnode);
					if(CProjectNode pn = cast(CProjectNode) node.GetRootNode())
						pn.SetProjectFileDirty(true);
				}
			}
			return S_OK;
		}
		return returnError(E_FAIL);
	}
}

class GlobalPropertyPage : PropertyPage
{
	abstract void SetControls(GlobalOptions options);
	abstract int  DoApply(GlobalOptions options, GlobalOptions refoptions);

	this(GlobalOptions options)
	{
		mOptions = options;
	}

	override void UpdateControls()
	{
		if(GlobalOptions options = GetGlobalOptions())
			SetControls(options);
	}

	GlobalOptions GetGlobalOptions()
	{
		return mOptions;
	}

	void SetWindowSize(int x, int y, int w, int h)
	{
		mixin(LogCallMix);
		if(mCanvas)
			mCanvas.setRect(x, y, w, h);
	}

	/*override*/ int IsPageDirty()
	{
		mixin(LogCallMix);
		if(mWindow)
			if(GlobalOptions options = GetGlobalOptions())
			{
				scope GlobalOptions opt = new GlobalOptions;
				return DoApply(opt, options) > 0 ? S_OK : S_FALSE;
			}
		return S_FALSE;
	}

	/*override*/ int Apply()
	{
		mixin(LogCallMix);

		if(GlobalOptions options = GetGlobalOptions())
		{
			DoApply(options, options);
			options.saveToRegistry();
			return S_OK;
		}
		return returnError(E_FAIL);
	}

	GlobalOptions mOptions;
}

///////////////////////////////////////////////////////////////////////////////
class CommonPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return ""; }
	override string GetPageName() { return "General"; }

	override void CreateControls() 
	{
		AddControl("Build System",  mCbBuildSystem = new ComboBox(mCanvas, [ "Visual D", "dsss", "rebuild" ], false));
		mCbBuildSystem.setSelection(0);
		mCbBuildSystem.setEnabled(false);
	}
	override void SetControls(ProjectOptions options) 
	{
	}
	override int DoApply(ProjectOptions options, ProjectOptions refoptions) 
	{
		return 0; 
	}

	ComboBox mCbBuildSystem;
}

class GeneralPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return ""; }
	override string GetPageName() { return "General"; }

	const float[] selectableVersions = [ 1, 2 ];
	
	override void CreateControls()
	{
		string[] versions;
		foreach(ver; selectableVersions)
			versions ~= "D" ~ to!(string)(ver);
		//versions[$-1] ~= "+";
		
		AddControl("Compiler",      mCompiler = new ComboBox(mCanvas, [ "DMD", "GDC" ], false));
		AddControl("D-Version",     mDVersion = new ComboBox(mCanvas, versions, false));
		AddControl("Output Type",   mCbOutputType = new ComboBox(mCanvas, 
																 [ "Executable", "Library", "DLL" ], false));
		AddControl("Subsystem",     mCbSubsystem = new ComboBox(mCanvas, 
																[ "Not set", "Console", "Windows", "Native", "Posix" ], false));
		AddControl("Output Path",   mOutputPath = new Text(mCanvas));
		AddControl("Intermediate Path", mIntermediatePath = new Text(mCanvas));
		AddControl("Files to clean", mFilesToClean = new Text(mCanvas));
		AddControl("",              mOtherDMD = new CheckBox(mCanvas, "Use other compiler"));
		AddControl("Compiler Path", mDmdPath = new Text(mCanvas));
		AddControl("Compilation",   mSingleFileComp = new ComboBox(mCanvas, 
			[ "Combined compile and link", "Single file compilation", 
			  "Separate compile and link", "Compile only (use Post-build command to link)" ], false));
	}

	override void UpdateDirty(bool bDirty)
	{
		super.UpdateDirty(bDirty);
		EnableControls();
	}
	
	void EnableControls()
	{
		mDmdPath.setEnabled(mOtherDMD.isChecked());
	}

	override void SetControls(ProjectOptions options)
	{
		int ver = 0;
		while(ver < selectableVersions.length - 1 && selectableVersions[ver+1] <= options.Dversion)
			ver++;
		mDVersion.setSelection(ver);
		
		mOtherDMD.setChecked(options.otherDMD);
		mCompiler.setSelection(options.compiler);
		mSingleFileComp.setSelection(options.compilationModel);
		mCbOutputType.setSelection(options.lib);
		mCbSubsystem.setSelection(options.subsystem);
		mDmdPath.setText(options.program);
		mOutputPath.setText(options.outdir);
		mIntermediatePath.setText(options.objdir);
		mFilesToClean.setText(options.filesToClean);
		
		EnableControls();
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		float ver = selectableVersions[mDVersion.getSelection()];
		int changes = 0;
		changes += changeOption(mOtherDMD.isChecked(), options.otherDMD, refoptions.otherDMD);
		changes += changeOption(cast(ubyte) mCompiler.getSelection(), options.compiler, refoptions.compiler);
		changes += changeOption(cast(uint) mSingleFileComp.getSelection(), options.compilationModel, refoptions.compilationModel);
		changes += changeOption(cast(ubyte) mCbOutputType.getSelection(), options.lib, refoptions.lib);
		changes += changeOption(cast(ubyte) mCbSubsystem.getSelection(), options.subsystem, refoptions.subsystem);
		changes += changeOption(mDmdPath.getText(), options.program, refoptions.program);
		changes += changeOption(ver, options.Dversion, refoptions.Dversion);
		changes += changeOption(mOutputPath.getText(), options.outdir, refoptions.outdir);
		changes += changeOption(mIntermediatePath.getText(), options.objdir, refoptions.objdir);
		changes += changeOption(mFilesToClean.getText(), options.filesToClean, refoptions.filesToClean);
		return changes;
	}

	CheckBox mOtherDMD;
	ComboBox mCompiler;
	ComboBox mSingleFileComp;
	Text mDmdPath;
	ComboBox mCbOutputType;
	ComboBox mCbSubsystem;
	ComboBox mDVersion;
	Text mOutputPath;
	Text mIntermediatePath;
	Text mFilesToClean;
}

class DebuggingPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return ""; }
	override string GetPageName() { return "Debugging"; }

	override void CreateControls()
	{
		Label lbl;
		AddControl("Command",           mCommand = new Text(mCanvas));
		AddControl("Command Arguments", mArguments = new Text(mCanvas));
		AddControl("Working Directory", mWorkingDir = new Text(mCanvas));
		AddControl("",                  mAttach = new CheckBox(mCanvas, "Attach to running process"));
		AddControl("Remote Machine",    mRemote = new Text(mCanvas));
		AddControl("Debugger",          mDebugEngine = new ComboBox(mCanvas, [ "Visual Studio", "Mago", "Visual Studio (x86 Mixed Mode)" ], false));
		AddControl("",                  mStdOutToOutputWindow = new CheckBox(mCanvas, "Redirect stdout to output window"));
		AddControl("Run without debugging", lbl = new Label(mCanvas, ""));
		AddControl("",                  mPauseAfterRunning = new CheckBox(mCanvas, "Pause when program finishes"));

		lbl.AddWindowExStyle(WS_EX_STATICEDGE);
		lbl.AddWindowStyle(SS_ETCHEDFRAME, SS_TYPEMASK);
		int left, top, w, h;
		if(lbl.getRect(left, top, w, h))
			lbl.setRect(left, top + h / 2 - 1, w, 2);
	}

	override void UpdateDirty(bool bDirty)
	{
		super.UpdateDirty(bDirty);
		EnableControls();
	}

	void EnableControls()
	{
		mStdOutToOutputWindow.setEnabled(mDebugEngine.getSelection() != 1);
	}

	override void SetControls(ProjectOptions options)
	{
		mCommand.setText(options.debugtarget);
		mArguments.setText(options.debugarguments);
		mWorkingDir.setText(options.debugworkingdir);
		mAttach.setChecked(options.debugattach);
		mRemote.setText(options.debugremote);
		mDebugEngine.setSelection(options.debugEngine);
		mStdOutToOutputWindow.setChecked(options.debugStdOutToOutputWindow);
		mPauseAfterRunning.setChecked(options.pauseAfterRunning);

		EnableControls();
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mCommand.getText(), options.debugtarget, refoptions.debugtarget);
		changes += changeOption(mArguments.getText(), options.debugarguments, refoptions.debugarguments);
		changes += changeOption(mWorkingDir.getText(), options.debugworkingdir, refoptions.debugworkingdir);
		changes += changeOption(mAttach.isChecked(), options.debugattach, options.debugattach);
		changes += changeOption(mRemote.getText(), options.debugremote, refoptions.debugremote);
		changes += changeOption(cast(ubyte)mDebugEngine.getSelection(), options.debugEngine, refoptions.debugEngine);
		changes += changeOption(mStdOutToOutputWindow.isChecked(), options.debugStdOutToOutputWindow, options.debugStdOutToOutputWindow);
		changes += changeOption(mPauseAfterRunning.isChecked(), options.pauseAfterRunning, options.pauseAfterRunning);
		return changes;
	}

	Text mCommand;
	Text mArguments;
	Text mWorkingDir;
	Text mRemote;
	CheckBox mAttach;
	ComboBox mDebugEngine;
	CheckBox mStdOutToOutputWindow;
	CheckBox mPauseAfterRunning;
}

class DmdGeneralPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return "Compiler"; }
	override string GetPageName() { return "General"; }

	override void CreateControls()
	{
		AddControl("",                    mUseStandard = new CheckBox(mCanvas, "Use Standard Import Paths"));
		AddControl("Additional Imports",  mAddImports = new Text(mCanvas));
		AddControl("String Imports",      mStringImports = new Text(mCanvas));
		AddControl("Version Identifiers", mVersionIdentifiers = new Text(mCanvas));
		AddControl("Debug Identifiers",   mDebugIdentifiers = new Text(mCanvas));
	}

	override void SetControls(ProjectOptions options)
	{
		mUseStandard.setChecked(true);
		mUseStandard.setEnabled(false);

		mAddImports.setText(options.imppath);
		mStringImports.setText(options.fileImppath);
		mVersionIdentifiers.setText(options.versionids);
		mDebugIdentifiers.setText(options.debugids);
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mAddImports.getText(), options.imppath, refoptions.imppath);
		changes += changeOption(mStringImports.getText(), options.fileImppath, refoptions.fileImppath);
		changes += changeOption(mVersionIdentifiers.getText(), options.versionids, refoptions.versionids);
		changes += changeOption(mDebugIdentifiers.getText(), options.debugids, refoptions.debugids);
		return changes;
	}

	CheckBox mUseStandard;
	Text mAddImports;
	Text mStringImports;
	Text mVersionIdentifiers;
	Text mDebugIdentifiers;
}

class DmdDebugPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return "Compiler"; }
	override string GetPageName() { return "Debug"; }

	override void CreateControls()
	{
		AddControl("Debug Mode", mDebugMode = new ComboBox(mCanvas, [ "Off (release)", "On" ], false));
		AddControl("Debug Info", mDebugInfo = new ComboBox(mCanvas, [ "None", "Symbolic", "Symbolic (pretend to be C)" ], false));
		AddControl("",           mRunCv2pdb = new CheckBox(mCanvas, "Run cv2pdb to Convert Debug Info"));
		AddControl("Path to cv2pdb", mPathCv2pdb = new Text(mCanvas));
		AddControl("",           mCv2pdbPre2043  = new CheckBox(mCanvas, "Assume old associative array implementation (before dmd 2.043)"));
		AddControl("",           mCv2pdbNoDemangle = new CheckBox(mCanvas, "Do not demangle symbols"));
		AddControl("",           mCv2pdbEnumType = new CheckBox(mCanvas, "Use enumerator types"));
		AddControl("More options", mCv2pdbOptions  = new Text(mCanvas));
	}

	override void UpdateDirty(bool bDirty)
	{
		super.UpdateDirty(bDirty);
		EnableControls();
	}
	
	void EnableControls()
	{
		mPathCv2pdb.setEnabled(mRunCv2pdb.isChecked());
		mCv2pdbOptions.setEnabled(mRunCv2pdb.isChecked());
		mCv2pdbEnumType.setEnabled(mRunCv2pdb.isChecked());
		mCv2pdbPre2043.setEnabled(mRunCv2pdb.isChecked());
		mCv2pdbNoDemangle.setEnabled(mRunCv2pdb.isChecked());
	}

	override void SetControls(ProjectOptions options)
	{
		mDebugMode.setSelection(options.release ? 0 : 1);
		mDebugInfo.setSelection(options.symdebug);
		mRunCv2pdb.setChecked(options.runCv2pdb);
		mPathCv2pdb.setText(options.pathCv2pdb);
		mCv2pdbOptions.setText(options.cv2pdbOptions);
		mCv2pdbPre2043.setChecked(options.cv2pdbPre2043);
		mCv2pdbNoDemangle.setChecked(options.cv2pdbNoDemangle);
		mCv2pdbEnumType.setChecked(options.cv2pdbEnumType);

		EnableControls();
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mDebugMode.getSelection() == 0, options.release, refoptions.release);
		changes += changeOption(cast(ubyte) mDebugInfo.getSelection(), options.symdebug, refoptions.symdebug);
		changes += changeOption(mRunCv2pdb.isChecked(), options.runCv2pdb, refoptions.runCv2pdb);
		changes += changeOption(mPathCv2pdb.getText(), options.pathCv2pdb, refoptions.pathCv2pdb);
		changes += changeOption(mCv2pdbOptions.getText(), options.cv2pdbOptions, refoptions.cv2pdbOptions);
		changes += changeOption(mCv2pdbPre2043.isChecked(), options.cv2pdbPre2043, refoptions.cv2pdbPre2043);
		changes += changeOption(mCv2pdbNoDemangle.isChecked(), options.cv2pdbNoDemangle, refoptions.cv2pdbNoDemangle);
		changes += changeOption(mCv2pdbEnumType.isChecked(), options.cv2pdbEnumType, refoptions.cv2pdbEnumType);
		return changes;
	}

	ComboBox mDebugMode;
	ComboBox mDebugInfo;
	CheckBox mRunCv2pdb;
	Text mPathCv2pdb;
	CheckBox mCv2pdbPre2043;
	CheckBox mCv2pdbNoDemangle;
	CheckBox mCv2pdbEnumType;
	Text mCv2pdbOptions;
}

class DmdCodeGenPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return "Compiler"; }
	override string GetPageName() { return "Code Generation"; }

	override void CreateControls()
	{
		mUnindentCheckBox = kLabelWidth;
		AddControl("", mProfiling     = new CheckBox(mCanvas, "Insert Profiling Hooks"));
		AddControl("", mCodeCov       = new CheckBox(mCanvas, "Generate Code Coverage"));
		AddControl("", mOptimizer     = new CheckBox(mCanvas, "Run Optimizer"));
		AddControl("", mNoboundscheck = new CheckBox(mCanvas, "No Array Bounds Checking"));
		AddControl("", mUnitTests     = new CheckBox(mCanvas, "Generate Unittest Code"));
		AddControl("", mInline        = new CheckBox(mCanvas, "Expand Inline Functions"));
		AddControl("", mNoFloat       = new CheckBox(mCanvas, "No Floating Point Support"));
		AddControl("", mGenStackFrame = new CheckBox(mCanvas, "Always generate stack frame (DMD 2.056+)"));
	}

	override void SetControls(ProjectOptions options)
	{
		mProfiling.setChecked(options.trace); 
		mCodeCov.setChecked(options.cov); 
		mOptimizer.setChecked(options.optimize);
		mNoboundscheck.setChecked(options.noboundscheck); 
		mUnitTests.setChecked(options.useUnitTests);
		mInline.setChecked(options.useInline);
		mNoFloat.setChecked(options.nofloat);
		mGenStackFrame.setChecked(options.genStackFrame);

		mNoboundscheck.setEnabled(options.Dversion > 1);
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mCodeCov.isChecked(), options.cov, refoptions.cov);
		changes += changeOption(mProfiling.isChecked(), options.trace, refoptions.trace);
		changes += changeOption(mOptimizer.isChecked(), options.optimize, refoptions.optimize);
		changes += changeOption(mNoboundscheck.isChecked(), options.noboundscheck, refoptions.noboundscheck);
		changes += changeOption(mUnitTests.isChecked(), options.useUnitTests, refoptions.useUnitTests);
		changes += changeOption(mInline.isChecked(), options.useInline, refoptions.useInline);
		changes += changeOption(mNoFloat.isChecked(), options.nofloat, refoptions.nofloat);
		changes += changeOption(mGenStackFrame.isChecked(), options.genStackFrame, refoptions.genStackFrame);
		return changes;
	}

	CheckBox mCodeCov;
	CheckBox mProfiling;
	CheckBox mOptimizer;
	CheckBox mNoboundscheck;
	CheckBox mUnitTests;
	CheckBox mInline;
	CheckBox mNoFloat;
	CheckBox mGenStackFrame;
}

class DmdMessagesPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return "Compiler"; }
	override string GetPageName() { return "Messages"; }

	override void CreateControls()
	{
		mUnindentCheckBox = kLabelWidth;
		AddControl("", mWarnings      = new CheckBox(mCanvas, "Enable Warnings"));
		AddControl("", mInfoWarnings  = new CheckBox(mCanvas, "Enable Informational Warnings (DMD 2.041+)"));
		AddControl("", mQuiet         = new CheckBox(mCanvas, "Suppress Non-Error Messages"));
		AddControl("", mVerbose       = new CheckBox(mCanvas, "Verbose Compile"));
		AddControl("", mVtls          = new CheckBox(mCanvas, "Show TLS Variables"));
		AddControl("", mUseDeprecated = new CheckBox(mCanvas, "Allow Deprecated Features"));
		AddControl("", mIgnorePragmas = new CheckBox(mCanvas, "Ignore Unsupported Pragmas"));
		AddControl("", mCheckProperty = new CheckBox(mCanvas, "Enforce Property Syntax (DMD 2.055+)"));
	}

	override void SetControls(ProjectOptions options)
	{
		mWarnings.setChecked(options.warnings);
		mInfoWarnings.setChecked(options.infowarnings);
		mQuiet.setChecked(options.quiet);
		mVerbose.setChecked(options.verbose);
		mVtls.setChecked(options.vtls);
		mUseDeprecated.setChecked(options.useDeprecated);
		mIgnorePragmas.setChecked(options.ignoreUnsupportedPragmas);
		mCheckProperty.setChecked(options.checkProperty);

		mVtls.setEnabled(options.Dversion > 1);
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mWarnings.isChecked(), options.warnings, refoptions.warnings);
		changes += changeOption(mInfoWarnings.isChecked(), options.infowarnings, refoptions.infowarnings);
		changes += changeOption(mQuiet.isChecked(), options.quiet, refoptions.quiet);
		changes += changeOption(mVerbose.isChecked(), options.verbose, refoptions.verbose);
		changes += changeOption(mVtls.isChecked(), options.vtls, refoptions.vtls);
		changes += changeOption(mUseDeprecated.isChecked(), options.useDeprecated, refoptions.useDeprecated);
		changes += changeOption(mIgnorePragmas.isChecked(), options.ignoreUnsupportedPragmas, refoptions.ignoreUnsupportedPragmas);
		changes += changeOption(mCheckProperty.isChecked(), options.checkProperty, refoptions.checkProperty);
		return changes;
	}

	CheckBox mWarnings;
	CheckBox mInfoWarnings;
	CheckBox mQuiet;
	CheckBox mVerbose;
	CheckBox mVtls;
	CheckBox mUseDeprecated;
	CheckBox mIgnorePragmas;
	CheckBox mCheckProperty;
}

class DmdDocPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return "Compiler"; }
	override string GetPageName() { return "Documentation"; }

	override void CreateControls()
	{
		AddControl("", mGenDoc = new CheckBox(mCanvas, "Generate documentation"));
		AddControl("Documentation file", mDocFile = new Text(mCanvas));
		AddControl("Documentation dir", mDocDir = new Text(mCanvas));
		AddControl("CanDyDOC module", mModulesDDoc = new Text(mCanvas));
		
		AddControl("", mGenHdr = new CheckBox(mCanvas, "Generate interface headers"));
		AddControl("Header file",  mHdrFile = new Text(mCanvas));
		AddControl("Header directory",  mHdrDir = new Text(mCanvas));

		AddControl("", mGenJSON = new CheckBox(mCanvas, "Generate JSON file"));
		AddControl("JSON file",  mJSONFile = new Text(mCanvas));
	}

	override void UpdateDirty(bool bDirty)
	{
		super.UpdateDirty(bDirty);
		EnableControls();
	}
	
	void EnableControls()
	{
		mDocDir.setEnabled(mGenDoc.isChecked());
		mDocFile.setEnabled(mGenDoc.isChecked());
		mModulesDDoc.setEnabled(mGenDoc.isChecked());
		
		mHdrDir.setEnabled(mGenHdr.isChecked());
		mHdrFile.setEnabled(mGenHdr.isChecked());

		mJSONFile.setEnabled(mGenJSON.isChecked());
	}

	override void SetControls(ProjectOptions options)
	{
		mGenDoc.setChecked(options.doDocComments);
		mDocDir.setText(options.docdir);
		mDocFile.setText(options.docname);
		mModulesDDoc.setText(options.modules_ddoc);
		mGenHdr.setChecked(options.doHdrGeneration);
		mHdrDir.setText(options.hdrdir);
		mHdrFile.setText(options.hdrname);
		mGenJSON.setChecked(options.doXGeneration);
		mJSONFile.setText(options.xfilename);
		
		EnableControls();
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mGenDoc.isChecked(), options.doDocComments, refoptions.doDocComments);
		changes += changeOption(mDocDir.getText(), options.docdir, refoptions.docdir);
		changes += changeOption(mDocFile.getText(), options.docname, refoptions.docname);
		changes += changeOption(mModulesDDoc.getText(), options.modules_ddoc, refoptions.modules_ddoc);
		changes += changeOption(mGenHdr.isChecked(), options.doHdrGeneration, refoptions.doHdrGeneration);
		changes += changeOption(mHdrDir.getText(), options.hdrdir, refoptions.hdrdir);
		changes += changeOption(mHdrFile.getText(), options.hdrname, refoptions.hdrname);
		changes += changeOption(mGenJSON.isChecked(), options.doXGeneration, refoptions.doXGeneration);
		changes += changeOption(mJSONFile.getText(), options.xfilename, refoptions.xfilename);
		return changes;
	}

	CheckBox mGenDoc;
	Text mDocDir;
	Text mDocFile;
	Text mModulesDDoc;
	CheckBox mGenHdr;
	Text mHdrDir;
	Text mHdrFile;
	CheckBox mGenJSON;
	Text mJSONFile;
}

class DmdOutputPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return "Compiler"; }
	override string GetPageName() { return "Output"; }

	override void CreateControls()
	{
		mUnindentCheckBox = kLabelWidth;
		AddControl("", mMultiObj = new CheckBox(mCanvas, "Multiple Object Files"));
		AddControl("", mPreservePaths = new CheckBox(mCanvas, "Keep Path From Source File"));
	}

	override void SetControls(ProjectOptions options)
	{
		mMultiObj.setChecked(options.multiobj); 
		mPreservePaths.setChecked(options.preservePaths); 
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mMultiObj.isChecked(), options.multiobj, refoptions.multiobj); 
		changes += changeOption(mPreservePaths.isChecked(), options.preservePaths, refoptions.preservePaths); 
		return changes;
	}

	CheckBox mMultiObj;
	CheckBox mPreservePaths;
}

class DmdLinkerPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return "Linker"; }
	override string GetPageName() { return "General"; }

	override void CreateControls()
	{
		AddControl("Output File", mExeFile = new Text(mCanvas));
		AddControl("Object Files", mObjFiles = new Text(mCanvas));
		AddControl("Library Files", mLibFiles = new Text(mCanvas));
		AddControl("Library Search Path", mLibPaths = new Text(mCanvas));
		//AddControl("Library search paths only work if you have modified sc.ini to include DMD_LIB!", null);
		AddControl("Definition File", mDefFile = new Text(mCanvas));
		AddControl("Resource File",   mResFile = new Text(mCanvas));
		AddControl("Generate Map File", mGenMap = new ComboBox(mCanvas, 
			[ "Minimum", "Symbols By Address", "Standard", "Full", "With cross references" ], false));
		AddControl("", mImplib = new CheckBox(mCanvas, "Create import library"));
		AddControl("", mUseStdLibPath = new CheckBox(mCanvas, "Use standard library search paths"));
	}

	override void SetControls(ProjectOptions options)
	{
		mExeFile.setText(options.exefile); 
		mObjFiles.setText(options.objfiles); 
		mLibFiles.setText(options.libfiles);
		mLibPaths.setText(options.libpaths);
		mDefFile.setText(options.deffile); 
		mResFile.setText(options.resfile); 
		mGenMap.setSelection(options.mapverbosity); 
		mImplib.setChecked(options.createImplib);
		mUseStdLibPath.setChecked(options.useStdLibPath);
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mExeFile.getText(), options.exefile, refoptions.exefile); 
		changes += changeOption(mObjFiles.getText(), options.objfiles, refoptions.objfiles); 
		changes += changeOption(mLibFiles.getText(), options.libfiles, refoptions.libfiles); 
		changes += changeOption(mLibPaths.getText(), options.libpaths, refoptions.libpaths); 
		changes += changeOption(mDefFile.getText(), options.deffile, refoptions.deffile); 
		changes += changeOption(mResFile.getText(), options.resfile, refoptions.resfile); 
		changes += changeOption(cast(uint) mGenMap.getSelection(), options.mapverbosity, refoptions.mapverbosity); 
		changes += changeOption(mImplib.isChecked(), options.createImplib, refoptions.createImplib); 
		changes += changeOption(mUseStdLibPath.isChecked(), options.useStdLibPath, refoptions.useStdLibPath);
		return changes;
	}

	Text mExeFile;
	Text mObjFiles;
	Text mLibFiles;
	Text mLibPaths;
	Text mDefFile;
	Text mResFile;
	ComboBox mGenMap;
	CheckBox mImplib;
	CheckBox mUseStdLibPath;
}

class DmdEventsPropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return ""; }
	override string GetPageName() { return "Build Events"; }

	override void CreateControls()
	{
		AddControl("Pre-Build Command", mPreCmd = new MultiLineText(mCanvas));
		AddControl("Post-Build Command", mPostCmd = new MultiLineText(mCanvas));

		Label lab = new Label(mCanvas, "Use \"if errorlevel 1 goto reportError\" to cancel on error");
		lab.setRect(0, kPageHeight - kLineHeight, kPageWidth, kLineHeight); 
	}

	override void SetControls(ProjectOptions options)
	{
		mPreCmd.setText(options.preBuildCommand); 
		mPostCmd.setText(options.postBuildCommand); 
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mPreCmd.getText(), options.preBuildCommand, refoptions.preBuildCommand); 
		changes += changeOption(mPostCmd.getText(), options.postBuildCommand, refoptions.postBuildCommand); 
		return changes;
	}

	MultiLineText mPreCmd;
	MultiLineText mPostCmd;
}

class DmdCmdLinePropertyPage : ProjectPropertyPage
{
	override string GetCategoryName() { return ""; }
	override string GetPageName() { return "Command line"; }

	override void CreateControls()
	{
		AddControl("Command line", mCmdLine = new MultiLineText(mCanvas, "", 0, true));
		AddControl("Additional options", mAddOpt = new MultiLineText(mCanvas));
	}

	override void OnConfigModified()
	{
		if(ProjectOptions options = GetProjectOptions())
			if(mCmdLine && mCmdLine.hwnd)
				mCmdLine.setText(options.buildCommandLine(true, true, true));
	}

	override void SetControls(ProjectOptions options)
	{
		mCmdLine.setText(options.buildCommandLine(true, true, true));
		mAddOpt.setText(options.additionalOptions); 
	}

	override int DoApply(ProjectOptions options, ProjectOptions refoptions)
	{
		int changes = 0;
		changes += changeOption(mAddOpt.getText(), options.additionalOptions, refoptions.additionalOptions); 
		return changes;
	}

	MultiLineText mCmdLine;
	MultiLineText mAddOpt;
}

class FilePropertyPage : NodePropertyPage
{
	override string GetCategoryName() { return ""; }
	override string GetPageName() { return "File"; }

	override void CreateControls()
	{
		AddControl("Build Tool", mTool = new ComboBox(mCanvas, [ "Auto", "DMD", kToolResourceCompiler, "Custom", "None" ], false));
		AddControl("Build Command", mCustomCmd = new MultiLineText(mCanvas));
		AddControl("Other Dependencies", mDependencies = new Text(mCanvas));
		AddControl("Output File", mOutFile = new Text(mCanvas));
		AddControl("", mLinkOut = new CheckBox(mCanvas, "Add output to link"));
	}

	void enableControls(string tool)
	{
		bool isCustom = (tool == "Custom");
		bool isRc = (tool == kToolResourceCompiler);
		mCustomCmd.setEnabled(isCustom);
		mDependencies.setEnabled(isCustom || isRc);
		mOutFile.setEnabled(isCustom);
		mLinkOut.setEnabled(isCustom);
	}

	override void SetControls(CFileNode node)
	{
		string tool = node.GetTool();
		if(tool.length == 0)
			mTool.setSelection(0);
		else
			mTool.setSelection(mTool.findString(tool));

		enableControls(tool);
		mCustomCmd.setText(node.GetCustomCmd()); 
		mDependencies.setText(node.GetDependencies()); 
		mOutFile.setText(node.GetOutFile()); 
		mLinkOut.setChecked(node.GetLinkOutput()); 
	}

	override int DoApply(CFileNode node, CFileNode refnode)
	{
		int changes = 0;
		string tool = mTool.getText();
		if(tool == "Auto")
			tool = "";
		changes += changeOptionDg!string(tool, &node.SetTool, refnode.GetTool()); 
		changes += changeOptionDg!string(mCustomCmd.getText(), &node.SetCustomCmd, refnode.GetCustomCmd()); 
		changes += changeOptionDg!string(mDependencies.getText(), &node.SetDependencies, refnode.GetDependencies()); 
		changes += changeOptionDg!string(mOutFile.getText(), &node.SetOutFile, refnode.GetOutFile()); 
		changes += changeOptionDg!bool(mLinkOut.isChecked(), &node.SetLinkOutput, refnode.GetLinkOutput()); 
		enableControls(tool);
		return changes;
	}

	ComboBox mTool;
	MultiLineText mCustomCmd;
	Text mDependencies;
	Text mOutFile;
	CheckBox mLinkOut;
}

///////////////////////////////////////////////////////////////////////////////
class ToolsPropertyPage : GlobalPropertyPage
{
	override string GetCategoryName() { return "Projects"; }
	override string GetPageName() { return "D Directories"; }

	this(GlobalOptions options)
	{
		kNeededLines = 13;
		super(options);
	}

	override void CreateControls()
	{
		mLinesPerMultiLine = 3;
		AddControl("DMD install path", mDmdPath = new Text(mCanvas));
		AddControl("Executable paths", mExePath = new MultiLineText(mCanvas));
		mLinesPerMultiLine = 2;
		AddControl("Import paths",     mImpPath = new MultiLineText(mCanvas));
		AddControl("Library paths",    mLibPath = new MultiLineText(mCanvas));
		//AddControl("Library search paths only work if you have modified sc.ini to include DMD_LIB!", null);
		AddControl("JSON paths",       mJSNPath = new MultiLineText(mCanvas));
		AddControl("Resource includes", mIncPath = new Text(mCanvas));
	}

	override void SetControls(GlobalOptions opts)
	{
		mDmdPath.setText(opts.DMDInstallDir);
		mExePath.setText(opts.ExeSearchPath);
		mImpPath.setText(opts.ImpSearchPath);
		mLibPath.setText(opts.LibSearchPath);
		mIncPath.setText(opts.IncSearchPath);
		mJSNPath.setText(opts.JSNSearchPath);
	}

	override int DoApply(GlobalOptions opts, GlobalOptions refopts)
	{
		int changes = 0;
		changes += changeOption(mDmdPath.getText(), opts.DMDInstallDir, refopts.DMDInstallDir); 
		changes += changeOption(mExePath.getText(), opts.ExeSearchPath, refopts.ExeSearchPath); 
		changes += changeOption(mImpPath.getText(), opts.ImpSearchPath, refopts.ImpSearchPath); 
		changes += changeOption(mLibPath.getText(), opts.LibSearchPath, refopts.LibSearchPath); 
		changes += changeOption(mIncPath.getText(), opts.IncSearchPath, refopts.IncSearchPath); 
		changes += changeOption(mJSNPath.getText(), opts.JSNSearchPath, refopts.JSNSearchPath); 
		return changes;
	}

	Text mDmdPath;
	Text mIncPath;
	MultiLineText mExePath;
	MultiLineText mImpPath;
	MultiLineText mLibPath;
	MultiLineText mJSNPath;
}

///////////////////////////////////////////////////////////////////////////////
class ToolsProperty2Page : GlobalPropertyPage
{
	override string GetCategoryName() { return "Projects"; }
	override string GetPageName() { return "D Options"; }

	this(GlobalOptions options)
	{
		super(options);
	}

	override void CreateControls()
	{
		AddControl("", mTimeBuilds    = new CheckBox(mCanvas, "Show build time"));
		AddControl("", mSortProjects  = new CheckBox(mCanvas, "Sort project items"));
		AddControl("", mStopSlnBuild  = new CheckBox(mCanvas, "Stop solution build on error"));
		AddControl("", mDemangleError = new CheckBox(mCanvas, "Demangle names in link errors"));
		AddControl("", mOptlinkDeps   = new CheckBox(mCanvas, "Monitor OPTLINK dependencies"));
		//AddControl("Remove project item", mDeleteFiles = 
		//		   new ComboBox(mCanvas, [ "Do not delete file on disk", "Ask", "Delete file on disk" ]));
	}

	override void SetControls(GlobalOptions opts)
	{
		mTimeBuilds.setChecked(opts.timeBuilds);
		mSortProjects.setChecked(opts.sortProjects);
		mStopSlnBuild.setChecked(opts.stopSolutionBuild);
		mDemangleError.setChecked(opts.demangleError);
		mOptlinkDeps.setChecked(opts.optlinkDeps);
		//mDeleteFiles.setSelection(opts.deleteFiles + 1);
	}

	override int DoApply(GlobalOptions opts, GlobalOptions refopts)
	{
		int changes = 0;
		changes += changeOption(mTimeBuilds.isChecked(), opts.timeBuilds, refopts.timeBuilds); 
		changes += changeOption(mSortProjects.isChecked(), opts.sortProjects, refopts.sortProjects); 
		changes += changeOption(mStopSlnBuild.isChecked(), opts.stopSolutionBuild, refopts.stopSolutionBuild); 
		changes += changeOption(mDemangleError.isChecked(), opts.demangleError, refopts.demangleError); 
		changes += changeOption(mOptlinkDeps.isChecked(), opts.optlinkDeps, refopts.optlinkDeps); 
		//changes += changeOption(cast(byte) (mDeleteFiles.getSelection() - 1), opts.deleteFiles, refopts.deleteFiles); 
		return changes;
	}

	CheckBox mTimeBuilds;
	CheckBox mSortProjects;
	CheckBox mStopSlnBuild;
	CheckBox mDemangleError;
	CheckBox mOptlinkDeps;
	//ComboBox mDeleteFiles;
}

///////////////////////////////////////////////////////////////////////////////
class ColorizerPropertyPage : GlobalPropertyPage
{
	override string GetCategoryName() { return "Language"; }
	override string GetPageName() { return "Colorizer"; }

	this(GlobalOptions options)
	{
		super(options);
		kNeededLines = 11;
	}

	override void CreateControls()
	{
		AddControl("", mColorizeVersions = new CheckBox(mCanvas, "Colorize version and debug statements"));
		AddControl("", mAutoOutlining = new CheckBox(mCanvas, "Add outlining regions when opening D files"));
		AddControl("", mParseSource = new CheckBox(mCanvas, "Parse source for syntax errors"));
		AddControl("", mPasteIndent = new CheckBox(mCanvas, "Reindent new lines after paste"));
		AddControl("Colored types", mUserTypes = new MultiLineText(mCanvas));
	}

	override void SetControls(GlobalOptions opts)
	{
		mColorizeVersions.setChecked(opts.ColorizeVersions);
		mAutoOutlining.setChecked(opts.autoOutlining);
		mParseSource.setChecked(opts.parseSource);
		mPasteIndent.setChecked(opts.pasteIndent);
		mUserTypes.setText(opts.UserTypesSpec);

		//mSemantics.setEnabled(false);
	}

	override int DoApply(GlobalOptions opts, GlobalOptions refopts)
	{
		int changes = 0;
		changes += changeOption(mColorizeVersions.isChecked(), opts.ColorizeVersions, refopts.ColorizeVersions); 
		changes += changeOption(mAutoOutlining.isChecked(), opts.autoOutlining, refopts.autoOutlining); 
		changes += changeOption(mParseSource.isChecked(), opts.parseSource, refopts.parseSource); 
		changes += changeOption(mPasteIndent.isChecked(), opts.pasteIndent, refopts.pasteIndent); 
		changes += changeOption(mUserTypes.getText(), opts.UserTypesSpec, refopts.UserTypesSpec); 
		return changes;
	}

	CheckBox mColorizeVersions;
	CheckBox mAutoOutlining;
	CheckBox mParseSource;
	CheckBox mPasteIndent;
	MultiLineText mUserTypes;
}

///////////////////////////////////////////////////////////////////////////////
class IntellisensePropertyPage : GlobalPropertyPage
{
	override string GetCategoryName() { return "Language"; }
	override string GetPageName() { return "Intellisense"; }

	this(GlobalOptions options)
	{
		super(options);
	}

	override void CreateControls()
	{
		AddControl("", mSemantics = new CheckBox(mCanvas, "Expansions from semantics (very experimental)"));
		AddControl("", mExpandFromBuffer = new CheckBox(mCanvas, "Expansions from text buffer"));
		AddControl("", mExpandFromJSON = new CheckBox(mCanvas, "Expansions from JSON browse information"));
		AddControl("Show expansion when", mExpandTrigger = new ComboBox(mCanvas, [ "pressing Ctrl+Space", "writing '.'", "writing an identifier" ], false));
		AddControl("", mShowTypeInTooltip = new CheckBox(mCanvas, "Show type of expressions in tool tip (experimental)"));
	}

	override void SetControls(GlobalOptions opts)
	{
		mSemantics.setChecked(opts.projectSemantics);
		mExpandFromBuffer.setChecked(opts.expandFromBuffer);
		mExpandFromJSON.setChecked(opts.expandFromJSON);
		mExpandTrigger.setSelection(opts.expandTrigger);
		mShowTypeInTooltip.setChecked(opts.showTypeInTooltip);

		//mSemantics.setEnabled(false);
	}

	override int DoApply(GlobalOptions opts, GlobalOptions refopts)
	{
		int changes = 0;
		changes += changeOption(mSemantics.isChecked(), opts.projectSemantics, refopts.projectSemantics); 
		changes += changeOption(mExpandFromBuffer.isChecked(), opts.expandFromBuffer, refopts.expandFromBuffer); 
		changes += changeOption(mExpandFromJSON.isChecked(), opts.expandFromJSON, refopts.expandFromJSON); 
		changes += changeOption(cast(byte) mExpandTrigger.getSelection(), opts.expandTrigger, refopts.expandTrigger); 
		changes += changeOption(mShowTypeInTooltip.isChecked(), opts.showTypeInTooltip, refopts.showTypeInTooltip); 
		return changes;
	}

	CheckBox mSemantics;
	CheckBox mExpandFromBuffer;
	CheckBox mExpandFromJSON;
	ComboBox mExpandTrigger;
	CheckBox mShowTypeInTooltip;
}

///////////////////////////////////////////////////////////////////////////////
// more guids in dpackage.d starting up to 980f
const GUID    g_GeneralPropertyPage      = uuid("002a2de9-8bb6-484d-9810-7e4ad4084715");
const GUID    g_DmdGeneralPropertyPage   = uuid("002a2de9-8bb6-484d-9811-7e4ad4084715");
const GUID    g_DmdDebugPropertyPage     = uuid("002a2de9-8bb6-484d-9812-7e4ad4084715");
const GUID    g_DmdCodeGenPropertyPage   = uuid("002a2de9-8bb6-484d-9813-7e4ad4084715");
const GUID    g_DmdMessagesPropertyPage  = uuid("002a2de9-8bb6-484d-9814-7e4ad4084715");
const GUID    g_DmdOutputPropertyPage    = uuid("002a2de9-8bb6-484d-9815-7e4ad4084715");
const GUID    g_DmdLinkerPropertyPage    = uuid("002a2de9-8bb6-484d-9816-7e4ad4084715");
const GUID    g_DmdEventsPropertyPage    = uuid("002a2de9-8bb6-484d-9817-7e4ad4084715");
const GUID    g_CommonPropertyPage       = uuid("002a2de9-8bb6-484d-9818-7e4ad4084715");
const GUID    g_DebuggingPropertyPage    = uuid("002a2de9-8bb6-484d-9819-7e4ad4084715");
const GUID    g_FilePropertyPage         = uuid("002a2de9-8bb6-484d-981a-7e4ad4084715");
const GUID    g_DmdDocPropertyPage       = uuid("002a2de9-8bb6-484d-981b-7e4ad4084715");
const GUID    g_DmdCmdLinePropertyPage   = uuid("002a2de9-8bb6-484d-981c-7e4ad4084715");

// does not need to be registered, created explicitely by package
const GUID    g_ToolsPropertyPage        = uuid("002a2de9-8bb6-484d-9820-7e4ad4084715");
const GUID    g_ToolsProperty2Page       = uuid("002a2de9-8bb6-484d-9822-7e4ad4084715");

// registered under Languages\\Language Services\\D\\EditorToolsOptions\\Colorizer, created explicitely by package
const GUID    g_ColorizerPropertyPage    = uuid("002a2de9-8bb6-484d-9821-7e4ad4084715");
const GUID    g_IntellisensePropertyPage = uuid("002a2de9-8bb6-484d-9823-7e4ad4084715");

const GUID* guids_propertyPages[] = 
[ 
	&g_GeneralPropertyPage,
	&g_DmdGeneralPropertyPage,
	&g_DmdDebugPropertyPage,
	&g_DmdCodeGenPropertyPage,
	&g_DmdMessagesPropertyPage,
	&g_DmdOutputPropertyPage,
	&g_DmdLinkerPropertyPage,
	&g_DmdEventsPropertyPage,
	&g_CommonPropertyPage,
	&g_DebuggingPropertyPage,
	&g_FilePropertyPage,
	&g_DmdDocPropertyPage,
	&g_DmdCmdLinePropertyPage,
];

class PropertyPageFactory : DComObject, IClassFactory
{
	static PropertyPageFactory create(CLSID* rclsid)
	{
		foreach(id; guids_propertyPages)
			if(*id == *rclsid)
				return newCom!PropertyPageFactory(rclsid);
		return null;
	}

	this(CLSID* rclsid)
	{
		mClsid = *rclsid;
	}

	override HRESULT QueryInterface(in IID* riid, void** pvObject)
	{
		if(queryInterface2!(IClassFactory) (this, IID_IClassFactory, riid, pvObject))
			return S_OK;
		return super.QueryInterface(riid, pvObject);
	}

	override HRESULT CreateInstance(IUnknown UnkOuter, in IID* riid, void** pvObject)
	{
		PropertyPage ppp;
		assert(!UnkOuter);

		     if(mClsid == g_GeneralPropertyPage)
			ppp = newCom!GeneralPropertyPage();
		else if(mClsid == g_DebuggingPropertyPage)
			ppp = newCom!DebuggingPropertyPage();
		else if(mClsid == g_DmdGeneralPropertyPage)
			ppp = newCom!DmdGeneralPropertyPage();
		else if(mClsid == g_DmdDebugPropertyPage)
			ppp = newCom!DmdDebugPropertyPage();
		else if(mClsid == g_DmdCodeGenPropertyPage)
			ppp = newCom!DmdCodeGenPropertyPage();
		else if(mClsid == g_DmdMessagesPropertyPage)
			ppp = newCom!DmdMessagesPropertyPage();
		else if(mClsid == g_DmdDocPropertyPage)
			ppp = newCom!DmdDocPropertyPage();
		else if(mClsid == g_DmdOutputPropertyPage)
			ppp = newCom!DmdOutputPropertyPage();
		else if(mClsid == g_DmdLinkerPropertyPage)
			ppp = newCom!DmdLinkerPropertyPage();
		else if(mClsid == g_DmdEventsPropertyPage)
			ppp = newCom!DmdEventsPropertyPage();
		else if(mClsid == g_DmdCmdLinePropertyPage)
			ppp = newCom!DmdCmdLinePropertyPage();
		else if(mClsid == g_CommonPropertyPage)
			ppp = newCom!CommonPropertyPage();
		else if(mClsid == g_FilePropertyPage)
			ppp = newCom!FilePropertyPage();
		else
			return E_INVALIDARG;

		return ppp.QueryInterface(riid, pvObject);
	}

	override HRESULT LockServer(in BOOL fLock)
	{
		return S_OK;
	}

	static int GetProjectPages(CAUUID *pPages)
	{
version(all) {
		pPages.cElems = 11;
		pPages.pElems = cast(GUID*)CoTaskMemAlloc(pPages.cElems*GUID.sizeof);
		if (!pPages.pElems)
			return E_OUTOFMEMORY;

		pPages.pElems[0] = g_GeneralPropertyPage;
		pPages.pElems[1] = g_DebuggingPropertyPage;
		pPages.pElems[2] = g_DmdGeneralPropertyPage;
		pPages.pElems[3] = g_DmdDebugPropertyPage;
		pPages.pElems[4] = g_DmdCodeGenPropertyPage;
		pPages.pElems[5] = g_DmdMessagesPropertyPage;
		pPages.pElems[6] = g_DmdDocPropertyPage;
		pPages.pElems[7] = g_DmdOutputPropertyPage;
		pPages.pElems[8] = g_DmdLinkerPropertyPage;
		pPages.pElems[9] = g_DmdCmdLinePropertyPage;
		pPages.pElems[10] = g_DmdEventsPropertyPage;
		return S_OK;
} else {
		return returnError(E_NOTIMPL);
}
	}

	static int GetCommonPages(CAUUID *pPages)
	{
		pPages.cElems = 1;
		pPages.pElems = cast(GUID*)CoTaskMemAlloc(pPages.cElems*GUID.sizeof);
		if (!pPages.pElems)
			return E_OUTOFMEMORY;

		pPages.pElems[0] = g_CommonPropertyPage;
		return S_OK;
	}

	static int GetFilePages(CAUUID *pPages)
	{
		pPages.cElems = 1;
		pPages.pElems = cast(GUID*)CoTaskMemAlloc(pPages.cElems*GUID.sizeof);
		if (!pPages.pElems)
			return E_OUTOFMEMORY;

		pPages.pElems[0] = g_FilePropertyPage;
		return S_OK;
	}

private:
	GUID mClsid;
}

